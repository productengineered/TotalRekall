// RestoreMenuActions.swift
// Main-actor bridge between the menu (RestoreActions/SnapshotActions) and the RestoreCoordinator and
// SnapshotCoordinator actors. It shows the working state for the duration of a run and publishes the
// outcome to MenuBarViewModel: the last-result line, the attention icon when a restore is partial or
// failed, and the snapshot notice when Save Snapshot Now is refused.
// Save Snapshot Now goes through SnapshotCoordinator.saveManually: the SAME gated path as the
// scheduled snapshots (token, gated store commit, gated learning).

import Foundation
import os

extension MenuBarViewModel {
    /// Publishes a coordinator outcome. `previousState` is restored when the request was dropped
    /// because another run already owns the working state.
    func apply(_ outcome: RestoreOutcome, previousState: AppState = .idle) {
        switch outcome {
        case .refusedNoAccessibility:
            accessibilityGranted = false
            state = .idle
        case .droppedInFlight:
            state = previousState
        case .noSnapshot:
            hasSnapshot = false
            state = .idle
        case .restored(let summary):
            lastResult = summary.asRestoreResult()
            state = outcome.setsAttention ? .attention : .idle
            Task { await refreshLastRestoreDetail() }
        case .quietWake:
            // Nothing happened: Last restore, its detail and the icon stay as they were.
            state = previousState
        case .monitorsFixed(let fix, let date):
            if outcome.setsAttention {
                state = .attention
            } else {
                if case .alreadyInOrder = fix {
                    lastResult = .monitorsAlreadyInOrder(date: date)
                } else {
                    lastResult = .monitorsFixed(date: date)
                }
                setMonitorFixDetail(fix, date: date)
                state = .idle
            }
        case .failed:
            state = .attention
        }
    }
}

extension RestoreOutcome {
    /// Whether this outcome means "your layout is likely wrong": drives the attention icon and the
    /// problem notification from one shared rule.
    var setsAttention: Bool {
        switch self {
        case .restored(let summary): summary.needsAttention
        case .monitorsFixed(let fix, _): fix.setsAttention
        case .failed: true
        case .quietWake, .refusedNoAccessibility, .droppedInFlight, .noSnapshot: false
        }
    }
}

/// Save Snapshot Now (implemented by `SnapshotCoordinator`).
protocol ManualSnapshotSaving: Sendable {
    func saveManually() async -> ManualSaveResult
}

/// The restore side the menu needs (implemented by `RestoreCoordinator`).
protocol RestoreCoordinating: AutoRestoring {
    func hasSnapshot() async -> Bool
}

extension RestoreCoordinator: RestoreCoordinating {}

@MainActor
final class RestoreMenuActions: RestoreActions, SnapshotActions {
    private static let logger = Logger(subsystem: "com.productengineered.TotalRekall", category: "snapshot")
    private let coordinator: RestoreCoordinating
    private let snapshots: ManualSnapshotSaving
    /// Set after the view model is built (the view model takes this object as its dependency).
    weak var viewModel: MenuBarViewModel?

    init(coordinator: RestoreCoordinating, snapshots: ManualSnapshotSaving) {
        self.coordinator = coordinator
        self.snapshots = snapshots
    }

    func restoreNow() async {
        await run { await $0.restoreNow(context: .manual()) }
    }

    func fixMonitors() async {
        await run { await $0.fixMonitors(context: .manual()) }
    }

    func saveNow() async {
        switch await snapshots.saveManually() {
        case .saved:
            viewModel?.snapshotNotice = nil  // hasSnapshot is refreshed by `snapshotSaved()`
        case .savedAfterShrink(let count, let prior):
            viewModel?.snapshotNotice = Self.savedAfterShrinkNotice(windowCount: count, priorCount: prior)
        case .refused(let message):
            viewModel?.snapshotNotice = message
        case .failed(let detail):
            Self.logger.error("manual snapshot failed: \(detail)")
            viewModel?.snapshotNotice = String(localized: "The snapshot could not be saved.")
        }
    }

    /// "Saved N windows (was M)" with the singular for one window. No String Catalog yet, so the
    /// plural is chosen here; the prior count is always above 1 (a shrink below half of it).
    static func savedAfterShrinkNotice(windowCount count: Int, priorCount prior: Int) -> String {
        count == 1
            ? String(localized: "Saved 1 window (was \(prior))")
            : String(localized: "Saved \(count) windows (was \(prior))")
    }

    /// Observer for every written snapshot (scheduled, launch or manual): clears a stale refusal
    /// notice and refreshes Restore Now availability.
    func snapshotSaved() async {
        viewModel?.snapshotNotice = nil
        viewModel?.lastSnapshotDate = Date()
        await refreshHasSnapshot()
    }

    /// Call at launch so Restore Now is enabled when a snapshot already exists.
    func refreshHasSnapshot() async {
        viewModel?.hasSnapshot = await coordinator.hasSnapshot()
    }

    private func run(_ operation: (RestoreCoordinating) async -> RestoreOutcome) async {
        let previous = viewModel?.state ?? .idle
        viewModel?.state = .working
        let outcome = await operation(coordinator)
        viewModel?.apply(outcome, previousState: previous)
    }
}

/// Backs "Reveal Restore Log" with the real log file.
@MainActor
final class RestoreLogFileProvider: RestoreLogProviding {
    private let store: RestoreLogStore

    init(store: RestoreLogStore = RestoreLogStore()) { self.store = store }

    var hasLog: Bool { store.hasLog }
    var logURL: URL? { store.hasLog ? store.logURL : nil }
}

/// Adapts the throwing LaunchAtLoginService to the menu's non-throwing toggle.
@MainActor
final class LaunchAtLoginMenuAdapter: LaunchAtLoginControlling {
    private static let logger = Logger(subsystem: "com.productengineered.TotalRekall", category: "launch-at-login")
    private let service: LaunchAtLoginService

    init(service: LaunchAtLoginService) { self.service = service }

    var isEnabled: Bool { service.isEnabled }

    func setEnabled(_ enabled: Bool) {
        do {
            try service.setEnabled(enabled)
        } catch {
            Self.logger.error("launch at login change failed: \(String(describing: error))")
        }
    }
}
