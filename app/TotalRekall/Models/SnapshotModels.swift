import Foundation

// Codable models for the snapshot file format (schema v1.2). Pure value types: no SwiftUI, AppKit or AX dependencies.

/// Root of snapshots.json. Dictionary of display configurations keyed by `SnapshotKey`.
struct SnapshotFile: Codable, Sendable, Equatable {
    static let currentVersion: Int = 1

    var version: Int
    var configurations: [String: DisplayConfigSnapshot]

    init(version: Int = SnapshotFile.currentVersion,
         configurations: [String: DisplayConfigSnapshot] = [:]) {
        self.version = version
        self.configurations = configurations
    }
}

/// One entry per unique connected-display configuration.
struct DisplayConfigSnapshot: Codable, Sendable, Equatable, Identifiable {
    var id: String { fingerprint }
    var fingerprint: String
    var displayConfigName: String
    var displays: [DisplaySnapshot]
    var lastSnapshotDate: Date
    var windows: [WindowSnapshot]
    var spacesManifest: SpacesManifest?

    init(fingerprint: String,
         displayConfigName: String,
         displays: [DisplaySnapshot],
         lastSnapshotDate: Date,
         windows: [WindowSnapshot],
         spacesManifest: SpacesManifest? = nil) {
        self.fingerprint = fingerprint
        self.displayConfigName = displayConfigName
        self.displays = displays
        self.lastSnapshotDate = lastSnapshotDate
        self.windows = windows
        self.spacesManifest = spacesManifest
    }

    private enum CodingKeys: String, CodingKey {
        case fingerprint, displayConfigName, displays, lastSnapshotDate, windows, spacesManifest
    }
}

struct SnapshotSize: Codable, Sendable, Hashable {
    var width: Double
    var height: Double
}

struct SnapshotFrame: Codable, Sendable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct DisplaySnapshot: Codable, Sendable, Hashable {
    var vendorID: UInt32
    var productID: UInt32
    var serialNumber: String
    /// v1.2 identity anchor (IORegistry AlphanumericSerialNumber; "builtin" for the built-in panel).
    var panelSerial: String?
    /// Hint only (v1.2): port-bound, flips between identical panels on replug.
    var unitNumber: UInt32
    /// Always nil in v1 (reserved for v2).
    var iokitLocationPath: String?
    var resolution: SnapshotSize
    var scaleFactor: Double
    var displayName: String
    var originX: Int
    var originY: Int
    var isMain: Bool
    /// Ephemeral, debug only; never a match key.
    var cgDisplayID: UInt32?
}

struct WindowSnapshot: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var bundleID: String
    var appName: String
    /// v1.2 primary match key (CGWindowID). Session-scoped.
    var windowID: UInt32?
    var windowTitle: String
    /// Diagnostic only since v1.2.
    var windowIndex: Int
    var displayFingerprint: String?
    var displayIndex: Int
    /// v1.2 Space key, part 1.
    var panelSerial: String?
    /// v1.2 Space key, part 2 (1-based among user desktops; nil for fullscreen Spaces).
    var spaceOrdinal: Int?
    /// Hint only since v1.2.
    var spaceUUID: String?
    var spaceIndex: Int
    var frame: SnapshotFrame
    var isFullscreen: Bool
    var isMinimized: Bool
    var zOrder: Int
    /// True when the window is on more than one Space (all-desktops window). Restore leaves it alone.
    var sticky: Bool? = nil
    /// False when recorded from CG + SLS data only because AX cannot see windows on other desktops.
    var axVisible: Bool? = nil
    /// Why restore should not reposition this window (minimized and fullscreen are kept distinct).
    var skipReason: WindowSkipReason? = nil

    /// The v1.2 desktop key when both halves are present.
    var desktopKey: DesktopKey? {
        guard let panelSerial, let spaceOrdinal else { return nil }
        return DesktopKey(panelSerial: panelSerial, ordinal: spaceOrdinal)
    }
}

/// Separate skip reasons per PD-7: minimized and fullscreen windows are recorded, never repositioned.
enum WindowSkipReason: String, Codable, Sendable, Hashable {
    case minimized
    case fullscreen
}

struct SpacesManifest: Codable, Sendable, Equatable {
    var capturedAt: Date
    var orderedSpaces: [SpaceEntry]
}

struct SpaceEntry: Codable, Sendable, Hashable {
    var panelSerial: String?
    var ordinal: Int?
    var displayFingerprint: String
    var indexOnDisplay: Int
    var isFullscreen: Bool
    var spaceUUID: String?
}
