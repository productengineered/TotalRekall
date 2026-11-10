// DeskActions.swift
// Named desks (named desks), service side: the value types, the actor-facing protocol implemented by
// SnapshotCoordinator, and the main-actor bridge the menu view model talks to. No AppKit here; the
// prompt, rename window and Desks submenu are built on top of this by later tasks.

import Foundation

/// One desk for the Desks submenu and the status line.
struct DeskSummary: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    /// True for the desk whose monitors are connected right now (never for the built-in display alone).
    let isCurrent: Bool
}

/// A monitor set the app has not seen before, announced once after the connection settles. The desk
/// is already registered under `name` when this is emitted.
struct NewDeskEvent: Equatable, Sendable {
    let key: String
    let name: String
}

enum DeskRenameResult: Equatable, Sendable {
    case renamed(String)
    case invalid(DeskNameRules.Problem)
    case unknownDesk
}

enum DeskArrangementResult: Equatable, Sendable {
    case saved(windowCount: Int)
    /// Busy, untrusted, or the gate is closed; the text is menu-ready.
    case refused(String)
    /// The connected monitors are no longer that desk, so nothing was learned or saved.
    case notCurrentDesk
    case failed(String)
}

/// Desk operations on the engine side (implemented by `SnapshotCoordinator`). Every operation is keyed
/// by the desk key captured when the UI was shown, never by "whatever desk is current now".
protocol DeskManaging: Sendable {
    /// Registers the live desk and returns the new-desk event, or nil when the live set is the
    /// built-in display alone or its desk was already registered.
    func registerNewDesk(live: MonitorLayout) async -> NewDeskEvent?
    func deskSummaries() async -> [DeskSummary]
    func deskNames() async -> [String]
    func renameDesk(_ key: String, to name: String) async -> DeskRenameResult
    /// Re-learns the desk's layout and takes a snapshot now, only if the live desk is still `key`.
    func saveDeskArrangement(_ key: String) async -> DeskArrangementResult
    /// Drops the learned layout, the name and the desk's saved window configurations.
    func forgetDesk(_ key: String) async -> Bool
}

/// What the menu view model needs for desks.
@MainActor
protocol DeskActions: AnyObject {
    func deskSummaries() async -> [DeskSummary]
    func deskNames() async -> [String]
    func renameDesk(_ key: String, to name: String) async -> DeskRenameResult
    func saveDeskArrangement(_ key: String) async -> DeskArrangementResult
    func forgetDesk(_ key: String) async -> Bool
}

@MainActor
final class StubDeskActions: DeskActions {
    func deskSummaries() async -> [DeskSummary] { [] }
    func deskNames() async -> [String] { [] }
    func renameDesk(_ key: String, to name: String) async -> DeskRenameResult { .unknownDesk }
    func saveDeskArrangement(_ key: String) async -> DeskArrangementResult { .notCurrentDesk }
    func forgetDesk(_ key: String) async -> Bool { false }
}

/// Forwards desk operations to the engine.
@MainActor
final class DeskMenuActions: DeskActions {
    private let manager: DeskManaging

    init(manager: DeskManaging) { self.manager = manager }

    func deskSummaries() async -> [DeskSummary] { await manager.deskSummaries() }
    func deskNames() async -> [String] { await manager.deskNames() }
    func renameDesk(_ key: String, to name: String) async -> DeskRenameResult {
        await manager.renameDesk(key, to: name)
    }
    func saveDeskArrangement(_ key: String) async -> DeskArrangementResult {
        await manager.saveDeskArrangement(key)
    }
    func forgetDesk(_ key: String) async -> Bool { await manager.forgetDesk(key) }
}
