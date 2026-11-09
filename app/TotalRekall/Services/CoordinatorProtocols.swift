import Foundation

/// Overall app state that drives the menu bar icon and status line.
enum AppState: Equatable, Sendable {
    case idle
    case working
    case attention
}

/// Outcome of the most recent restore, shown in the menu's last-result line.
enum RestoreResult: Equatable, Sendable {
    case windows(restored: Int, total: Int, date: Date)
    case monitorsFixed(date: Date)
    /// A manual Fix Monitors found the layout already correct and applied nothing.
    case monitorsAlreadyInOrder(date: Date)
}

/// Implemented by the snapshot engine.
@MainActor
protocol SnapshotActions: AnyObject {
    func saveNow() async
}

/// Implemented by the restore engine.
@MainActor
protocol RestoreActions: AnyObject {
    func restoreNow() async
    func fixMonitors() async
}

/// Reports whether a restore log exists and where it lives.
@MainActor
protocol RestoreLogProviding: AnyObject {
    var hasLog: Bool { get }
    var logURL: URL? { get }
}

/// Inert implementations used until the engine stories land.
@MainActor
final class StubSnapshotActions: SnapshotActions {
    func saveNow() async {}
}

@MainActor
final class StubRestoreActions: RestoreActions {
    func restoreNow() async {}
    func fixMonitors() async {}
}

@MainActor
final class StubRestoreLogProvider: RestoreLogProviding {
    var hasLog: Bool { false }
    var logURL: URL? { nil }
}
