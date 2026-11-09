// DiagnosticsBundleBuilder.swift
// Stages the sanitized Export Diagnostics folder: the diary files, a title-redacted copy of the restore
// log, a snapshot summary, the display topology, app info and a manifest. Snapshots and the restore log
// are never copied raw because they hold window titles. Inputs are injected so tests need no live system.

import Foundation

struct DiagnosticsBundleProviders: Sendable {
    var diagnosticsFiles: @Sendable () -> [URL]
    var restoreLog: @Sendable () throws -> RestoreLog
    /// Whether restore-log.json exists, to tell "absent" from "undecodable".
    var restoreLogExists: @Sendable () -> Bool
    var snapshot: @Sendable () async throws -> SnapshotFile
    var displays: @Sendable () -> [LiveDisplay]
    var topology: @Sendable () async throws -> [DisplaySpaces]
    /// Panel serial -> 1-based ordinal of the desktop currently shown on it (empty when unknown).
    var currentDesktopOrdinals: @Sendable () async -> [String: Int]
    var appInfo: @Sendable () -> AppInfoReport
}

struct DiagnosticsBundleBuilder: Sendable {
    static let redactedTitle = "[redacted]"

    let providers: DiagnosticsBundleProviders
    var now: @Sendable () -> Date = { Date() }

    init(providers: DiagnosticsBundleProviders, now: @escaping @Sendable () -> Date = { Date() }) {
        self.providers = providers
        self.now = now
    }

    /// Live wiring over the app's stores.
    static func live(sink: DiagnosticsFileSink = DiagnosticsFileSink(),
                     restoreLogStore: RestoreLogStore = RestoreLogStore(),
                     snapshotStore: SnapshotStore = SnapshotStore(),
                     displayProvider: DisplayProviding = LiveDisplayProvider(),
                     topology: SpaceTopologyProviding,
                     capability: SpaceBridgeCapability,
                     accessibilityTrusted: @escaping @Sendable () -> Bool) -> DiagnosticsBundleBuilder {
        let providers = DiagnosticsBundleProviders(
            diagnosticsFiles: { (0..<DiagnosticsFileSink.maxFiles).map { sink.fileURL(index: $0) } },
            restoreLog: { try restoreLogStore.load() },
            restoreLogExists: { restoreLogStore.hasLog },
            snapshot: { try await snapshotStore.load() },
            displays: { displayProvider.currentDisplays() },
            topology: { try await topology.topology() },
            currentDesktopOrdinals: { [:] },
            appInfo: {
                let info = Bundle.main.infoDictionary
                let cap: String
                switch capability {
                case .full: cap = "full"
                case .positionOnly(let reason): cap = "positionOnly: \(reason)"
                }
                return AppInfoReport(
                    appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
                    build: info?["CFBundleVersion"] as? String ?? "unknown",
                    macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    spaceBridgeCapability: cap,
                    accessibilityTrusted: accessibilityTrusted())
            })
        return DiagnosticsBundleBuilder(providers: providers)
    }

    /// Writes the bundle contents into `folder` (created if needed) and returns the manifest.
    @discardableResult
    func build(into folder: URL) async throws -> DiagnosticsManifest {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var included: [String] = []
        var missing: [String] = []

        // Diary files
        let diaryFiles = providers.diagnosticsFiles().filter { fm.fileExists(atPath: $0.path) }
        if diaryFiles.isEmpty {
            missing.append("diagnostics")
        } else {
            let dir = folder.appendingPathComponent("diagnostics", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for url in diaryFiles {
                let dest = dir.appendingPathComponent(url.lastPathComponent)
                try fm.copyItem(at: url, to: dest)
                included.append("diagnostics/\(url.lastPathComponent)")
            }
        }

        // Restore log, titles blanked
        if providers.restoreLogExists() {
            if let log = try? providers.restoreLog() {
                try Self.redactedData(log).write(to: folder.appendingPathComponent("restore-log.json"), options: .atomic)
            } else {
                let note = "restore-log.json could not be read and was not included.\n"
                try Data(note.utf8).write(to: folder.appendingPathComponent("restore-log.json"))
                missing.append("restore-log (undecodable)")
            }
            included.append("restore-log.json")
        } else {
            missing.append("restore-log")
        }

        // Snapshot summary
        if let file = try? await providers.snapshot(), !file.configurations.isEmpty {
            try writeJSON(SnapshotSummaryReport.make(from: file), name: "snapshot-summary.json", in: folder)
            included.append("snapshot-summary.json")
        } else {
            missing.append("snapshot")
        }

        // Display topology
        let report = await topologyReport()
        try writeJSON(report, name: "display-topology.json", in: folder)
        included.append("display-topology.json")
        if report.spaces == "unavailable" { missing.append("spaces") }

        // App info
        try writeJSON(providers.appInfo(), name: "app-info.json", in: folder)
        included.append("app-info.json")

        let manifest = DiagnosticsManifest(createdAt: now(), filesIncluded: included + ["manifest.json"],
                                           inputsMissing: missing)
        try writeJSON(manifest, name: "manifest.json", in: folder)
        return manifest
    }

    /// The restore log as JSON with every window title replaced; nothing else changes.
    static func redactedData(_ log: RestoreLog) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        var root = try JSONSerialization.jsonObject(with: enc.encode(log)) as? [String: Any] ?? [:]
        let windows = (root["windows"] as? [[String: Any]] ?? []).map { window -> [String: Any] in
            var w = window
            w["title"] = redactedTitle
            return w
        }
        root["windows"] = windows
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private func topologyReport() async -> DisplayTopologyReport {
        let displays = providers.displays()
        let spaces = try? await providers.topology()
        let current = await providers.currentDesktopOrdinals()
        let entries = displays.map { d -> DisplayTopologyReport.Display in
            let serial = d.serialString
            var count: Int?
            if let spaces, let serial {
                count = spaces.first { s in
                    switch s.serial {
                    case .builtin: serial == "builtin"
                    case .panel(let p): p == serial
                    case .unavailable: false
                    }
                }?.userSpaces.count
            }
            let isBuiltIn: Bool
            if case .builtin = d.serial { isBuiltIn = true } else { isBuiltIn = false }
            return DisplayTopologyReport.Display(
                displayID: d.displayID, isBuiltIn: isBuiltIn,
                originX: d.frame.x, originY: d.frame.y, width: d.frame.width, height: d.frame.height,
                panelSerial: serial, desktopCount: count,
                currentDesktopOrdinal: serial.flatMap { current[$0] })
        }
        return DisplayTopologyReport(displays: entries, spaces: spaces == nil ? "unavailable" : "available")
    }

    private func writeJSON<T: Encodable>(_ value: T, name: String, in folder: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(value).write(to: folder.appendingPathComponent(name), options: .atomic)
    }
}
