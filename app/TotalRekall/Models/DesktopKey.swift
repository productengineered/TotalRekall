import Foundation

/// Identifies a user desktop independent of session-scoped Space IDs: the owning display's
/// panel serial ("builtin" for the built-in panel) plus the 1-based ordinal among that
/// display's user desktops (the snapshot file format's "Space key").
struct DesktopKey: Codable, Sendable, Hashable {
    var panelSerial: String
    var ordinal: Int
}
