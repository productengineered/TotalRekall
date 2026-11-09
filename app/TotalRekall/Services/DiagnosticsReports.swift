// DiagnosticsReports.swift
// Report models written into the Export Diagnostics bundle. They carry counts, serials and sizes only:
// never a window title (the bundle is meant to be shared with the developer).

import Foundation

/// Per-configuration summary of snapshots.json. Window titles are never included.
struct SnapshotSummaryReport: Codable, Equatable, Sendable {
    struct Configuration: Codable, Equatable, Sendable {
        let key: String
        let panelSerials: [String]
        let windowCount: Int
        /// "serial#ordinal" -> windows on that desktop; "unassigned" for windows without a desktop key.
        let windowCountsPerDesktop: [String: Int]
        let minimizedCount: Int
        let fullscreenCount: Int
    }

    let version: Int
    let configurations: [Configuration]

    static func make(from file: SnapshotFile) -> SnapshotSummaryReport {
        let configs = file.configurations.keys.sorted().compactMap { key -> Configuration? in
            guard let c = file.configurations[key] else { return nil }
            var perDesktop: [String: Int] = [:]
            for w in c.windows {
                let name = w.desktopKey.map { "\($0.panelSerial)#\($0.ordinal)" } ?? "unassigned"
                perDesktop[name, default: 0] += 1
            }
            return Configuration(
                key: key,
                panelSerials: c.displays.compactMap(\.panelSerial).sorted(),
                windowCount: c.windows.count,
                windowCountsPerDesktop: perDesktop,
                minimizedCount: c.windows.filter { $0.isMinimized || $0.skipReason == .minimized }.count,
                fullscreenCount: c.windows.filter { $0.isFullscreen || $0.skipReason == .fullscreen }.count)
        }
        return SnapshotSummaryReport(version: file.version, configurations: configs)
    }
}

/// The connected displays and their desktops. `spaces` is "unavailable" when Spaces could not be read.
struct DisplayTopologyReport: Codable, Equatable, Sendable {
    struct Display: Codable, Equatable, Sendable {
        let displayID: UInt32
        let isBuiltIn: Bool
        let originX: Double
        let originY: Double
        let width: Double
        let height: Double
        let panelSerial: String?
        /// Nil when Spaces were unavailable.
        let desktopCount: Int?
        /// Nil when Spaces were unavailable or the current desktop is unknown.
        let currentDesktopOrdinal: Int?
    }

    let displays: [Display]
    /// "available" or "unavailable".
    let spaces: String
}

struct AppInfoReport: Codable, Equatable, Sendable {
    let appVersion: String
    let build: String
    let macOSVersion: String
    /// "full" or "positionOnly: <reason>".
    let spaceBridgeCapability: String
    let accessibilityTrusted: Bool
}

/// What went into the bundle and what could not be read.
struct DiagnosticsManifest: Codable, Equatable, Sendable {
    let createdAt: Date
    let filesIncluded: [String]
    let inputsMissing: [String]
}
