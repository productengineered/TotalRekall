import Foundation

/// Typed failures from `SnapshotStore`.
enum SnapshotStoreError: Error, Equatable {
    case fileTooLarge(Int)
    case encodingFailed(String)
    case writeFailed(String)
    case readFailed(String)
}

/// Result of a guarded save. Skipped is not an error: the prior snapshot is intentionally kept.
enum SnapshotSaveOutcome: Equatable, Sendable {
    /// Written normally.
    case written
    /// Zero windows captured while a prior non-empty snapshot exists. File bytes untouched.
    case skippedZeroWindows(priorCount: Int)
    /// New count below 50% of prior, written because it was confirmed (a second agreeing capture at
    /// least one interval later) or explicitly accepted (Save Snapshot Now). The prior file is
    /// preserved as snapshots.last-good.json.
    case writtenKeepingLastGood(priorCount: Int, newCount: Int)
    /// New count below 50% of prior and not yet confirmed. NOT written: the restore source keeps the
    /// last trusted count. Remembered in memory so the next agreeing capture can confirm it.
    case heldUnconfirmedShrink(priorCount: Int, newCount: Int)
    /// The SnapshotGate closed (or moved to a newer epoch) before the write committed. Nothing on disk
    /// changed; the capture is discarded.
    case discardedGateClosed
}

/// Recorded when a corrupt file was archived on load.
struct SnapshotCorruptRecoveryInfo: Equatable, Sendable {
    let archivedTo: URL
    let reason: String
}

/// Atomic, guarded JSON store for snapshots.json. The directory is injected for tests.
///
/// Shrink rule (Bug 65, PRD FR-19): a capture below 50% of the stored count is never written on first
/// sight. It is held in memory (per key) and committed only when a second capture agrees with it
/// (within `shrinkAgreement`) at least `shrinkConfirmationGap` later, so a user who really closed
/// windows converges in one scheduler interval while a one-off bad capture never becomes the restore
/// source. The baseline is the stored count, which is always a trusted one. An explicit Save Snapshot
/// Now (`acceptShrink`) commits immediately. The pending shrink is in memory only: a relaunch costs at
/// most one extra interval.
///
/// A pending shrink is tied to the gate epoch it was seen at. Every hold set and every display close
/// moves the epoch forward, so a capture after a hold or close never confirms a shrink seen before it:
/// it starts a new first sighting. A discarded save (gate closed) drops all pending shrinks too.
actor SnapshotStore {
    static let maxFileBytes = 10_000_000
    static let maxConfigurations = 100
    static let shrinkThreshold = 0.5
    /// One scheduler interval (600 s) less a small allowance for tick jitter.
    static let defaultShrinkConfirmationGap: TimeInterval = 590
    /// Two shrunken captures "agree" when they differ by at most this fraction (and at least 1 window).
    static let shrinkAgreement = 0.1

    private struct PendingShrink {
        let count: Int
        let capturedAt: Date
        /// Gate epoch of the first sighting (nil without a token: store-level tests).
        let epoch: UInt64?
    }

    /// Writes bytes to a temp URL durably (fsync). Injected so tests can simulate failure.
    typealias TempWriter = @Sendable (Data, URL) throws -> Void

    static var defaultDirectory: URL {
        #if DEBUG
        // Test seam: `-TRAppSupportDirectory <path>` points every store at a fixture folder
        // (empty, corrupt or 18-app restore log) without touching the real data.
        let args = ProcessInfo.processInfo.arguments
        if let flag = args.firstIndex(of: "-TRAppSupportDirectory"), flag + 1 < args.count {
            return URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TotalRekall", isDirectory: true)
    }

    /// Creates `url` (and parents) if needed and keeps it owner-only (0700): it holds window titles.
    nonisolated static func ensurePrivateDirectory(_ url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    nonisolated let directory: URL
    nonisolated var snapshotURL: URL { directory.appendingPathComponent("snapshots.json") }
    nonisolated var lastGoodURL: URL { directory.appendingPathComponent("snapshots.last-good.json") }
    nonisolated var archivesDirectory: URL { directory.appendingPathComponent("archives", isDirectory: true) }

    private(set) var corruptRecoveryInfo: SnapshotCorruptRecoveryInfo?
    private let tempWriter: TempWriter
    private let shrinkConfirmationGap: TimeInterval
    private var pendingShrinks: [String: PendingShrink] = [:]

    init(directory: URL = SnapshotStore.defaultDirectory,
         tempWriter: @escaping TempWriter = SnapshotStore.durableWrite,
         shrinkConfirmationGap: TimeInterval = SnapshotStore.defaultShrinkConfirmationGap) {
        self.directory = directory
        self.tempWriter = tempWriter
        self.shrinkConfirmationGap = shrinkConfirmationGap
    }

    // MARK: - Load

    /// Returns the stored file, or an empty one when absent. Corrupt/oversized/newer files are
    /// archived and an empty file is returned (see `corruptRecoveryInfo`).
    func load() throws -> SnapshotFile {
        let url = snapshotURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return SnapshotFile() }
        do {
            let size = (try fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size > Self.maxFileBytes {
                return try archiveAndReset(reason: "file larger than \(Self.maxFileBytes) bytes")
            }
            let data = try Data(contentsOf: url)
            let file: SnapshotFile
            do {
                file = try Self.decoder.decode(SnapshotFile.self, from: data)
            } catch {
                return try archiveAndReset(reason: "decode failed: \(error)")
            }
            if file.version < 1 || file.version > SnapshotFile.currentVersion {
                return try archiveAndReset(reason: "unsupported version \(file.version)")
            }
            if file.configurations.count > Self.maxConfigurations {
                return try archiveAndReset(reason: "config count exceeded")
            }
            return file
        } catch let error as SnapshotStoreError {
            throw error
        } catch {
            throw SnapshotStoreError.readFailed("\(error)")
        }
    }

    // MARK: - Save

    /// Guarded save of one configuration under `key`.
    ///
    /// With `token`, the write commits only if the SnapshotGate is still open at the token's epoch.
    /// Temp files are staged first; the check and the final renames then run under the gate lock, so
    /// no snapshot file changes after the first display callback. Production callers always pass a
    /// token (SnapshotService); `nil` is for store-level tests only.
    /// - Parameter acceptShrink: commit a <50% shrink immediately (explicit Save Snapshot Now only).
    func save(_ config: DisplayConfigSnapshot, key: String,
              ifGate token: SnapshotGateToken? = nil, acceptShrink: Bool = false) throws -> SnapshotSaveOutcome {
        if let token, !token.isValid {
            pendingShrinks.removeAll()
            return .discardedGateClosed
        }
        var file = try load()
        let priorCount = file.configurations[key]?.windows.count ?? 0
        let newCount = config.windows.count

        if newCount == 0 && priorCount > 0 {
            return .skippedZeroWindows(priorCount: priorCount)
        }

        let suspect = priorCount > 0 && Double(newCount) / Double(priorCount) < Self.shrinkThreshold
        if suspect && !acceptShrink
            && !confirmsPendingShrink(key: key, count: newCount, at: config.lastSnapshotDate, epoch: token?.epoch) {
            return .heldUnconfirmedShrink(priorCount: priorCount, newCount: newCount)
        }
        file.configurations[key] = config
        // Same cap load() enforces: evict the oldest other configs so load() never archives the store.
        while file.configurations.count > Self.maxConfigurations {
            guard let oldest = file.configurations
                .filter({ $0.key != key })
                .min(by: { $0.value.lastSnapshotDate < $1.value.lastSnapshotDate })?.key else { break }
            file.configurations.removeValue(forKey: oldest)
        }
        let data = try encode(file)

        var staged: [URL] = []
        defer { for url in staged { try? FileManager.default.removeItem(at: url) } }
        let lastGoodTemp = suspect ? try stageLastGood() : nil
        if let lastGoodTemp { staged.append(lastGoodTemp) }
        let temp = try stage(data, prefix: "snapshots")
        staged.append(temp)

        let committed = try commit(token) { () throws(SnapshotStoreError) in
            if let lastGoodTemp { try swapIn(lastGoodTemp, at: lastGoodURL, label: "last-good") }
            try swapIn(temp, at: snapshotURL, label: "snapshots")
        }
        guard committed else {
            pendingShrinks.removeAll()
            return .discardedGateClosed
        }
        pendingShrinks[key] = nil
        return suspect ? .writtenKeepingLastGood(priorCount: priorCount, newCount: newCount) : .written
    }

    /// True when `count` confirms the pending shrink for `key` (agreeing count, same gate epoch, captured
    /// at least one interval after it). Otherwise records `count` as the pending shrink (keeping the
    /// original time when it agrees, so early repeats never push confirmation back) and returns false.
    private func confirmsPendingShrink(key: String, count: Int, at date: Date, epoch: UInt64?) -> Bool {
        if let pending = pendingShrinks[key], pending.epoch == epoch, Self.shrinkCountsAgree(pending.count, count) {
            return date.timeIntervalSince(pending.capturedAt) >= shrinkConfirmationGap
        }
        pendingShrinks[key] = PendingShrink(count: count, capturedAt: date, epoch: epoch)
        return false
    }

    static func shrinkCountsAgree(_ lhs: Int, _ rhs: Int) -> Bool {
        let tolerance = max(1, Int((Double(max(lhs, rhs)) * shrinkAgreement).rounded(.up)))
        return abs(lhs - rhs) <= tolerance
    }

    /// Runs `body` under the gate lock when a token is given, otherwise directly.
    private func commit(_ token: SnapshotGateToken?, _ body: () throws(SnapshotStoreError) -> Void)
        throws(SnapshotStoreError) -> Bool {
        guard let token else {
            try body()
            return true
        }
        return try token.commitIfValid(body)
    }

    /// Explicit user "Clear Configuration": the only path allowed to reduce a config to zero windows.
    func clearConfig(key: String) throws {
        pendingShrinks[key] = nil
        var file = try load()
        guard var config = file.configurations[key] else { return }
        if !config.windows.isEmpty { try preserveLastGood() }
        config.windows = []
        file.configurations[key] = config
        try atomicReplace(with: try encode(file))
    }

    /// Reads the last-good copy if present.
    func loadLastGood() throws -> SnapshotFile? {
        guard FileManager.default.fileExists(atPath: lastGoodURL.path) else { return nil }
        do {
            return try Self.decoder.decode(SnapshotFile.self, from: Data(contentsOf: lastGoodURL))
        } catch {
            throw SnapshotStoreError.readFailed("\(error)")
        }
    }

    // MARK: - Internals

    private func encode(_ file: SnapshotFile) throws -> Data {
        let data: Data
        do {
            data = try Self.encoder.encode(file)
        } catch {
            throw SnapshotStoreError.encodingFailed("\(error)")
        }
        guard data.count <= Self.maxFileBytes else { throw SnapshotStoreError.fileTooLarge(data.count) }
        return data
    }

    private func preserveLastGood() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: snapshotURL.path) else { return }
        do {
            let data = try Data(contentsOf: snapshotURL)
            let temp = directory.appendingPathComponent(".snapshots.last-good.\(UUID().uuidString).tmp")
            try tempWriter(data, temp)
            try swapIn(temp, at: lastGoodURL)
        } catch {
            throw SnapshotStoreError.writeFailed("last-good: \(error)")
        }
    }

    /// Writes `data` durably to a fresh temp file in the store directory. Removes it on failure.
    private func stage(_ data: Data, prefix: String) throws -> URL {
        let fm = FileManager.default
        let temp = directory.appendingPathComponent(".\(prefix).\(UUID().uuidString).tmp")
        do {
            try Self.ensurePrivateDirectory(directory)
            try tempWriter(data, temp)
            return temp
        } catch {
            try? fm.removeItem(at: temp)
            throw SnapshotStoreError.writeFailed("\(prefix): \(error)")
        }
    }

    /// Stages a copy of the current snapshots.json for the last-good slot, or nil if there is none.
    private func stageLastGood() throws -> URL? {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: snapshotURL)
        } catch {
            throw SnapshotStoreError.writeFailed("last-good: \(error)")
        }
        return try stage(data, prefix: "snapshots.last-good")
    }

    /// Typed-throwing swap used inside the gate lock.
    private func swapIn(_ temp: URL, at target: URL, label: String) throws(SnapshotStoreError) {
        do {
            try swapIn(temp, at: target)
        } catch {
            throw SnapshotStoreError.writeFailed("\(label): \(error)")
        }
    }

    /// Temp write + fsync (via `tempWriter`) + replace. The target is never partially written.
    private func atomicReplace(with data: Data) throws {
        let fm = FileManager.default
        let temp = directory.appendingPathComponent(".snapshots.\(UUID().uuidString).tmp")
        do {
            try Self.ensurePrivateDirectory(directory)
            try tempWriter(data, temp)
            try swapIn(temp, at: snapshotURL)
        } catch {
            try? fm.removeItem(at: temp)
            throw SnapshotStoreError.writeFailed("\(error)")
        }
    }

    private func swapIn(_ temp: URL, at target: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: target)
        }
    }

    private func archiveAndReset(reason: String) throws -> SnapshotFile {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: archivesDirectory, withIntermediateDirectories: true)
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            let name = "snapshots-backup-\(stamp.string(from: Date()))-\(UUID().uuidString.prefix(6)).json"
            let dest = archivesDirectory.appendingPathComponent(name)
            try fm.moveItem(at: snapshotURL, to: dest)
            corruptRecoveryInfo = SnapshotCorruptRecoveryInfo(archivedTo: dest, reason: reason)
        } catch {
            throw SnapshotStoreError.readFailed("archive failed: \(error)")
        }
        return SnapshotFile()
    }

    /// Default temp writer: write, fsync, close.
    static let durableWrite: TempWriter = { data, url in
        let fm = FileManager.default
        guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private static var encoder: JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }

    private static var decoder: JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }
}
