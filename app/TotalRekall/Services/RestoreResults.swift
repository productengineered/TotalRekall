// RestoreResults.swift
// Per-window restore statuses, the restored-of-total summary that drives the menu line and the
// attention icon, and the Codable log model written by RestoreLogStore.
// Named RestoreStatus/RestoreWindowResult/RestoreSummary: `RestoreResult` already exists in
// CoordinatorProtocols.swift as the menu's last-result value.

import Foundation

enum RestoreStatus: Equatable, Sendable, Hashable {
    /// Repositioned via AX and read back within tolerance.
    case moved
    /// AX accepted the write but the read-back differed.
    case movedUnverified
    /// AX could not reach the window.
    case axUnreachable
    /// Moved to the saved desktop (frame already correct or not needed).
    case spaceMoved
    case alreadyCorrect
    /// A Space move was attempted and never confirmed.
    case failed
    case skipped(RestoreSkipReason)

    var logValue: String {
        switch self {
        case .moved: "moved"
        case .movedUnverified: "moved-unverified"
        case .axUnreachable: "ax-unreachable"
        case .spaceMoved: "space-moved"
        case .alreadyCorrect: "already-correct"
        case .failed: "failed"
        case .skipped(let reason): "skipped:\(reason.rawValue)"
        }
    }

    init?(logValue: String) {
        switch logValue {
        case "moved": self = .moved
        case "moved-unverified": self = .movedUnverified
        case "ax-unreachable": self = .axUnreachable
        case "space-moved": self = .spaceMoved
        case "already-correct": self = .alreadyCorrect
        case "failed": self = .failed
        default:
            let prefix = "skipped:"
            guard logValue.hasPrefix(prefix),
                  let reason = RestoreSkipReason(rawValue: String(logValue.dropFirst(prefix.count)))
            else { return nil }
            self = .skipped(reason)
        }
    }

    /// Skips that are the user's recorded intent, not a restore shortfall.
    var isIntentionalSkip: Bool {
        switch self {
        case .skipped(.minimized), .skipped(.fullscreen), .skipped(.sticky): true
        default: false
        }
    }

    /// Not restored, but not misplaced by the restore either: the window stayed where it was.
    var isLeftInPlace: Bool {
        switch self {
        case .axUnreachable, .skipped(.notFound), .skipped(.panelNotConnected), .skipped(.untitledNoAXMatch): true
        default: false
        }
    }

    /// The window ended where the snapshot says it belongs.
    var isRestored: Bool {
        switch self {
        case .moved, .movedUnverified, .spaceMoved, .alreadyCorrect: true
        default: false
        }
    }
}

extension RestoreStatus: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = RestoreStatus(logValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Unknown restore status \(raw)"))
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(logValue)
    }
}

struct RestoreWindowResult: Equatable, Sendable, Codable {
    let snapshotID: UUID
    let windowID: UInt32?
    let bundleID: String
    let appName: String
    let title: String
    let status: RestoreStatus
    let detail: String?

    init(planned: PlannedWindow, status: RestoreStatus, detail: String? = nil) {
        self.snapshotID = planned.snapshotID
        self.windowID = planned.windowID
        self.bundleID = planned.bundleID
        self.appName = planned.appName
        self.title = planned.title
        self.status = status
        self.detail = detail
    }

    init(snapshotID: UUID, windowID: UInt32?, bundleID: String, appName: String, title: String,
         status: RestoreStatus, detail: String? = nil) {
        self.snapshotID = snapshotID
        self.windowID = windowID
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.status = status
        self.detail = detail
    }

    /// Status for a window the plan decided not to touch (skips and already-correct).
    static func fromPlanOnly(_ planned: PlannedWindow) -> RestoreWindowResult? {
        switch planned.action {
        case .alreadyCorrect: RestoreWindowResult(planned: planned, status: .alreadyCorrect)
        case .skip(let reason): RestoreWindowResult(planned: planned, status: .skipped(reason))
        default: nil
        }
    }
}

/// Counts and flags for the menu's last-restore line and the attention icon.
struct RestoreSummary: Equatable, Sendable {
    /// Windows that count toward "Y": everything except intentional skips (minimized, fullscreen, sticky).
    let total: Int
    /// Windows that count toward "X": moved, moved-unverified, space-moved, already-correct.
    let restored: Int
    let unverified: Int
    let unreachable: Int
    let failed: Int
    let desktopMissing: Int
    let intentionallySkipped: Int
    /// Windows the restore could not place but that were left where they were (ax-unreachable after
    /// a confirmed move-back, not-found, panel-not-connected). Shown in the detail and log only.
    let leftInPlace: Int
    /// The monitor fix that ran before this restore failed or could not be verified.
    let monitorFixFailed: Bool
    let date: Date

    init(results: [RestoreWindowResult], date: Date, monitorFix: FixOutcome? = nil) {
        let statuses = results.map(\.status)
        let counted = statuses.filter { !$0.isIntentionalSkip }
        self.total = counted.count
        self.restored = counted.filter(\.isRestored).count
        self.unverified = counted.filter { $0 == .movedUnverified }.count
        self.unreachable = counted.filter { $0 == .axUnreachable }.count
        self.failed = counted.filter { $0 == .failed }.count
        self.desktopMissing = counted.filter { $0 == .skipped(.desktopMissing) }.count
        self.intentionallySkipped = statuses.count - counted.count
        self.leftInPlace = counted.filter(\.isLeftInPlace).count
        self.monitorFixFailed = Self.isFixFailure(monitorFix)
        self.date = date
    }

    private static func isFixFailure(_ outcome: FixOutcome?) -> Bool {
        switch outcome {
        case .failed, .unverified: true
        case .verified, .alreadyInOrder, .skipped, nil: false
        }
    }

    /// Nothing that should have been restored was. A zero-window restore is not a failure.
    var isFailed: Bool { total > 0 && restored == 0 }

    /// Some restored, but not everything, or something could not be verified.
    var isPartial: Bool { !isFailed && (restored < total || unverified > 0) }

    /// The attention icon means "your layout is likely wrong": the monitor fix failed, a window was
    /// written but not verified, a Space move failed, or a saved desktop no longer exists.
    /// Windows left in place (ax-unreachable after a confirmed move-back, not-found, panel not
    /// connected) are not misplaced: they stay visible in the last-result detail and the log only.
    var needsAttention: Bool { monitorFixFailed || unverified > 0 || failed > 0 || desktopMissing > 0 }

    /// "Last restore: X of Y windows, h:mm a"
    func menuLine(timeZone: TimeZone = .current) -> String {
        "Last restore: \(restored) of \(total) windows, \(Self.timeFormatter(timeZone).string(from: date))"
    }

    func asRestoreResult() -> RestoreResult {
        .windows(restored: restored, total: total, date: date)
    }

    private static func timeFormatter(_ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "h:mm a"
        return f
    }
}

// MARK: - Quiet wake

/// Decides whether a finished wake restore provably did nothing, so it may stay out of Last restore,
/// restore-log.json and notifications. Pure: the coordinator and the automation controller only
/// gather the inputs. Errs toward NOT quiet: any doubt about the snapshot, the monitors or a single
/// window means a normal restore. Windows the restore deliberately never touches (minimized,
/// full-screen, sticky, closed since the snapshot) are quiet-compatible, but at least one window must
/// have been verified already-correct, so an all-skipped cycle is never quiet.
enum QuietWakePolicy {
    /// One saved window of the snapshot the restore used (own windows included; the policy drops them).
    struct SnapshotWindow: Equatable, Sendable {
        let id: UUID
        let bundleID: String
    }

    struct Input: Sendable {
        let trigger: CycleTrigger
        let eligibility: QuietWakeEligibility?
        let fix: FixOutcome
        /// The configuration loaded from snapshots.json for the connected displays.
        let snapshotWindows: [SnapshotWindow]
        let ownBundleID: String?
        let results: [RestoreWindowResult]
    }

    static func isQuiet(_ input: Input) -> Bool {
        guard input.trigger == .wake,
              let eligibility = input.eligibility,
              !eligibility.displaysAddedOrRemoved,
              !eligibility.resumedByHoldBound,
              input.fix == .alreadyInOrder
        else { return false }
        let userWindows = input.snapshotWindows.filter { $0.bundleID != input.ownBundleID }
        guard !userWindows.isEmpty, !input.results.isEmpty else { return false }
        let reported = Set(input.results.map(\.snapshotID))
        guard userWindows.allSatisfy({ reported.contains($0.id) }) else { return false }
        guard input.results.allSatisfy({ isQuietCompatible($0.status) }) else { return false }
        return input.results.contains { $0.status == .alreadyCorrect }
    }

    /// Exhaustive on purpose: a new status must be decided explicitly. Statuses that moved, failed or
    /// could not be placed disqualify; ones the restore leaves alone by design do not.
    private static func isQuietCompatible(_ status: RestoreStatus) -> Bool {
        switch status {
        case .alreadyCorrect: true
        case .skipped(let reason):
            switch reason {
            case .minimized, .fullscreen, .sticky, .notFound: true
            case .desktopMissing, .panelNotConnected, .untitledNoAXMatch: false
            }
        case .moved, .movedUnverified, .spaceMoved, .axUnreachable, .failed: false
        }
    }
}

// MARK: - Log model

struct RestoreLogOrigin: Codable, Equatable, Sendable {
    let x: Int
    let y: Int
}

/// The JSON written to restore-log.json: what was restored, with what layout, and per-window outcomes.
struct RestoreLog: Codable, Equatable, Sendable {
    struct Counts: Codable, Equatable, Sendable {
        let total: Int
        let restored: Int
        let unverified: Int
        let unreachable: Int
        let failed: Int
        let desktopMissing: Int
        let intentionallySkipped: Int
    }

    let restoredAt: Date
    let configKey: String?
    /// "full" or "positionOnly: <reason>".
    let capability: String
    /// Panel serial to origin of the monitor layout in force for this restore.
    let layout: [String: RestoreLogOrigin]
    let counts: Counts
    let needsAttention: Bool
    /// The monitor fix outcome that preceded this restore (nil in logs written before it was recorded).
    let monitorFix: String?
    let windows: [RestoreWindowResult]
    /// Why this restore ran (nil in logs written before triggers were recorded).
    let trigger: CycleTrigger?
    /// Ties this log to the diagnostics trail (nil in logs written before cycle IDs were recorded).
    let cycleID: UUID?

    init(results: [RestoreWindowResult], date: Date, configKey: String?,
         capability: SpaceBridgeCapability, layout: MonitorLayout?, monitorFix: FixOutcome? = nil,
         context: CycleContext? = nil) {
        self.trigger = context?.trigger
        self.cycleID = context?.cycleID
        let summary = RestoreSummary(results: results, date: date, monitorFix: monitorFix)
        self.restoredAt = date
        self.configKey = configKey
        switch capability {
        case .full: self.capability = "full"
        case .positionOnly(let reason): self.capability = "positionOnly: \(reason)"
        }
        self.layout = (layout?.origins ?? [:]).mapValues { RestoreLogOrigin(x: $0.x, y: $0.y) }
        self.counts = Counts(total: summary.total, restored: summary.restored, unverified: summary.unverified,
                             unreachable: summary.unreachable, failed: summary.failed,
                             desktopMissing: summary.desktopMissing,
                             intentionallySkipped: summary.intentionallySkipped)
        self.needsAttention = summary.needsAttention
        self.monitorFix = monitorFix.map { String(describing: $0) }
        self.windows = results
    }
}
