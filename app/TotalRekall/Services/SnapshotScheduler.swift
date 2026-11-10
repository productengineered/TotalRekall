// SnapshotScheduler.swift
// Fires one snapshot at launch (call `start()` after the monitor check) and then every 10 minutes,
// on the injected AppClock. The tick is gated by SnapshotCoordinator, so paused ticks write
// nothing. No pre-sleep snapshot (not chosen).

import Foundation
import os

actor SnapshotScheduler {
    static let defaultInterval: Duration = .seconds(600)

    private let clock: AppClock
    private let interval: Duration
    private let tick: @Sendable () async -> Void
    private let diagnostics: DiagnosticsRecording
    private var loop: Task<Void, Never>?
    private(set) var tickCount = 0

    init(clock: AppClock = SystemClock(), interval: Duration = SnapshotScheduler.defaultInterval,
         diagnostics: DiagnosticsRecording = DiagnosticsLog.shared,
         tick: @escaping @Sendable () async -> Void) {
        self.diagnostics = diagnostics
        self.clock = clock
        self.interval = interval
        self.tick = tick
    }

    func start() {
        guard loop == nil else { return }
        let clock = clock, interval = interval, tick = tick
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.recordTickStart()
                await tick()
                await self?.recordTick()
                do { try await clock.sleep(for: interval) } catch { return }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    private func recordTick() { tickCount += 1 }

    private func recordTickStart() {
        diagnostics.record(DiagnosticsEvent(.snapshot, "scheduler-tick", fields: ["tick": .int(tickCount + 1)]))
    }
}

// MARK: - Coordinator

protocol SnapshotCapturing: Sendable {
    func capture(reason: SnapshotReason, gate token: SnapshotGateToken) async throws -> SnapshotCaptureResult
}

extension SnapshotService: SnapshotCapturing {}

enum ManualSaveResult: Equatable, Sendable {
    case saved(windowCount: Int)
    /// Saved, replacing a snapshot with more than twice as many windows (accepted as user intent).
    case savedAfterShrink(windowCount: Int, priorCount: Int)
    /// Refused during the pause; `message` is shown in the menu.
    case refused(message: String)
    case failed(String)
}

/// The one gated path for every snapshot: scheduled ticks (including the launch snapshot) and
/// Save Snapshot Now. Each attempt takes a SnapshotGate token before reading anything; the store
/// write and the learned-layout update each re-check that token at commit and discard the capture if
/// a display callback arrived in between.
actor SnapshotCoordinator {
    private static let logger = Logger(subsystem: "com.productengineered.TotalRekall", category: "snapshot")

    nonisolated let gate: SnapshotGate
    private let capturer: SnapshotCapturing
    private let learnedStore: LearnedLayoutStore
    private let liveLayout: @Sendable () -> MonitorLayout
    private var saveObserver: (@Sendable () async -> Void)?
    private let diagnostics: DiagnosticsRecording
    private let isTrusted: (@Sendable () -> Bool)?

    /// - Parameters:
    ///   - gate: shared with DisplayMonitor (closes it) and AutomationController (reopens it).
    ///   - liveLayout: current panel-serial -> origin map (for the docked-set rule).
    ///   - isTrusted: Accessibility check for desk actions; nil skips it (the capture itself fails untrusted).
    init(
        capturer: SnapshotCapturing,
        gate: SnapshotGate,
        learnedStore: LearnedLayoutStore = LearnedLayoutStore(),
        liveLayout: @escaping @Sendable () -> MonitorLayout,
        diagnostics: DiagnosticsRecording = DiagnosticsLog.shared,
        isTrusted: (@Sendable () -> Bool)? = nil
    ) {
        self.isTrusted = isTrusted
        self.diagnostics = diagnostics
        self.capturer = capturer
        self.gate = gate
        self.learnedStore = learnedStore
        self.liveLayout = liveLayout
    }

    /// How the live monitor set relates to the learned desks, with the matching desk's own layout.
    func deskLookup(live: MonitorLayout) async -> DeskLookup { await learnedStore.lookup(live: live) }

    /// Called after every snapshot that was written to disk (scheduled or manual), e.g. to refresh
    /// the menu's Restore Now availability.
    func setSaveObserver(_ observer: @escaping @Sendable () async -> Void) {
        saveObserver = observer
    }

    // MARK: Snapshots

    /// Scheduler tick. Silently skipped while the gate is closed.
    func runScheduledSnapshot() async {
        _ = await snapshot(reason: .periodic)
    }

    /// Save Snapshot Now. Refused with a menu message while the gate is closed.
    func saveManually() async -> ManualSaveResult {
        switch await snapshot(reason: .manual) {
        case .saved(let count): .saved(windowCount: count)
        case .savedAfterShrink(let count, let prior): .savedAfterShrink(windowCount: count, priorCount: prior)
        case .refused(let refusal): .refused(message: refusal.message)
        case .notSaved(let message): .refused(message: message)
        // Unreachable: a manual save accepts the shrink (acceptShrink). Kept total without menu text.
        case .heldForConfirmation: .failed("unconfirmed shrink on a manual save")
        case .failed(let message): .failed(message)
        }
    }

    /// Menu text when a manual save found no windows (the zero-window guard kept the saved file).
    static var zeroWindowsMessage: String {
        String(localized: "No windows were found to save. Your saved snapshot was kept.")
    }

    private enum Attempt {
        case saved(Int)
        case savedAfterShrink(Int, prior: Int)
        case refused(SnapshotRefusal)
        /// Nothing written for a reason with its own menu text (zero windows, unreadable windows).
        case notSaved(String)
        /// Under-half shrink held until a second capture confirms it (scheduled captures only).
        case heldForConfirmation
        case failed(String)
    }

    private func snapshot(reason: SnapshotReason) async -> Attempt {
        // Token first: everything read after this point is invalidated by a later callback.
        guard let token = gate.token() else {
            let refusal = gate.refusal
            recordNotTaken(reason: reason, code: "gate-closed", refusal: refusal, epoch: gate.epoch)
            return .refused(refusal)
        }
        let lookup = await learnedStore.lookup(live: liveLayout())
        if let refusal = SnapshotPolicy.dockedSetRefusal(lookup: lookup) {
            recordNotTaken(reason: reason, code: "docked-set-absent", refusal: refusal, epoch: token.epoch)
            return .refused(refusal)
        }
        do {
            let result = try await capturer.capture(reason: reason, gate: token)
            switch result.outcome {
            case .discardedGateClosed:
                Self.logger.info("snapshot discarded: display change began during capture")
                let refusal = gate.refusal
                recordNotTaken(reason: reason, code: "gate-discarded-at-commit", refusal: refusal, epoch: token.epoch)
                return .refused(refusal)
            case .skippedZeroWindows(let prior):
                var fields: [String: DiagnosticsValue] = [
                    "reason": .string("zero-window-guard"), "priorWindows": .int(prior),
                    "trigger": .code(reason)
                ]
                fields.merge(Self.joinFields(result.join)) { old, _ in old }
                diagnostics.record(DiagnosticsEvent(.snapshot, "snapshot-skipped", fields: fields))
                return .notSaved(Self.zeroWindowsMessage)
            case .heldUnconfirmedShrink(let prior, let new):
                var fields: [String: DiagnosticsValue] = [
                    "reason": .string("shrink-unconfirmed"), "priorWindows": .int(prior),
                    "newWindows": .int(new), "trigger": .code(reason)
                ]
                fields.merge(Self.joinFields(result.join)) { old, _ in old }
                diagnostics.record(DiagnosticsEvent(.snapshot, "snapshot-skipped", fields: fields))
                return .heldForConfirmation
            case .written, .writtenKeepingLastGood:
                recordWritten(result)
                await learnedStore.learn(result.layout, ifGate: token)
                await saveObserver?()
                if case .writtenKeepingLastGood(let prior, let new) = result.outcome {
                    return .savedAfterShrink(new, prior: prior)
                }
                return .saved(result.windowCount)
            }
        } catch {
            recordFailed(error, reason: reason)
            Self.logger.error("snapshot failed: \(String(describing: error))")
            if let message = (error as? SnapshotCaptureError)?.menuMessage { return .notSaved(message) }
            return .failed(String(describing: error))
        }
    }
}

extension SnapshotCoordinator {
    /// Records a snapshot that was not taken. A manual Save Snapshot Now is a refusal the user sees;
    /// a scheduled tick is a silent skip.
    private func recordNotTaken(reason: SnapshotReason, code: String, refusal: SnapshotRefusal, epoch: UInt64) {
        let fields: [String: DiagnosticsValue] = [
            "reason": .string(code), "refusal": .string(refusal.trailCode),
            "epoch": .int(Int(truncatingIfNeeded: epoch)), "trigger": .code(reason)
        ]
        let name = reason == .manual ? "snapshot-refused" : "snapshot-skipped"
        diagnostics.record(DiagnosticsEvent(.snapshot, name, fields: fields))
    }

    private func recordWritten(_ result: SnapshotCaptureResult) {
        var fields: [String: DiagnosticsValue] = [
            "panelSerials": .int(result.layout.origins.count),
            "windows": .int(result.windowCount),
            "trigger": .code(result.reason)
        ]
        if case .writtenKeepingLastGood(let prior, let new) = result.outcome {
            fields["anomalyGuard"] = .bool(true)
            fields["priorWindows"] = .int(prior)
            fields["newWindows"] = .int(new)
            fields["shrink"] = .string(result.reason == .manual ? "accepted-manual" : "confirmed")
        }
        fields.merge(Self.joinFields(result.join)) { old, _ in old }
        diagnostics.record(DiagnosticsEvent(.snapshot, "snapshot-written", fields: fields))
    }

    /// `snapshot-failed`, with the join counts when the AX join collapsed.
    private func recordFailed(_ error: Error, reason: SnapshotReason) {
        var fields: [String: DiagnosticsValue] = ["reason": .string(Self.failureCode(error)), "trigger": .code(reason)]
        if case .axJoinCollapsed(let join)? = error as? SnapshotCaptureError {
            fields.merge(Self.joinFields(join)) { old, _ in old }
        }
        diagnostics.record(DiagnosticsEvent(.snapshot, "snapshot-failed", fields: fields))
    }

    /// Candidate count, AX-joined count and the first AXError code. Counts and codes only.
    static func joinFields(_ join: CaptureJoinStats?) -> [String: DiagnosticsValue] {
        guard let join else { return [:] }
        var fields: [String: DiagnosticsValue] = ["candidates": .int(join.candidates), "axJoined": .int(join.axJoined)]
        if let code = join.firstAXError { fields["axError"] = .int(Int(code)) }
        return fields
    }

    private static func failureCode(_ error: Error) -> String {
        switch error as? SnapshotCaptureError {
        case .accessibilityNotGranted: "accessibility-not-granted"
        case .axWindowJoinUnavailable: "ax-window-join-unavailable"
        case .noDisplays: "no-displays"
        case .panelIdentityUnavailable: "panel-identity-unavailable"
        case .topologyUnavailable: "topology-unavailable"
        case .storeFailed: "store-failed"
        case .axJoinCollapsed: "ax-join-collapsed"
        case nil: "unknown"
        }
    }
}

private extension SnapshotRefusal {
    var trailCode: String {
        switch self {
        case .displayChangeInProgress: "display-change-in-progress"
        case .awaitingRestore: "awaiting-restore"
        case .restoring: "restoring"
        case .dockedSetAbsent: "docked-set-absent"
        case .accessibilityMissing: "accessibility-missing"
        case .layoutUnverified: "layout-unverified"
        case .screensAsleep: "screens-asleep"
        case .sessionNotReady: "session-not-ready"
        }
    }
}

extension SnapshotCoordinator: ManualSnapshotSaving {}

// MARK: - Desks (named desks)

extension SnapshotCoordinator: DeskManaging {
    func registerNewDesk(live: MonitorLayout) async -> NewDeskEvent? {
        guard DeskKey.hasExternalPanel(live), let key = DeskKey.make(for: live) else { return nil }
        let registration = await learnedStore.registerIfNeeded(key)
        return registration.isNew ? NewDeskEvent(key: key, name: registration.desk.name) : nil
    }

    func deskSummaries() async -> [DeskSummary] {
        let live = liveLayout()
        let currentKey = DeskKey.hasExternalPanel(live) ? DeskKey.make(for: live) : nil
        let desks = await learnedStore.desks
        let all = desks.map { DeskSummary(id: $0.key, name: $0.name, isCurrent: $0.key == currentKey) }
        return all.filter(\.isCurrent) + all.filter { !$0.isCurrent }
    }

    func deskNames() async -> [String] { await learnedStore.allNames }

    func renameDesk(_ key: String, to name: String) async -> DeskRenameResult {
        await learnedStore.rename(deskKey: key, to: name)
    }

    func forgetDesk(_ key: String) async -> Bool { await learnedStore.forget(deskKey: key) }

    /// Re-learn plus snapshot now, for the desk captured by the caller. Refused (not queued) while
    /// untrusted or while the gate is closed. The one closed-gate state it may override is
    /// `layoutUnverified`: re-learning the layout IS how the user resolves that hold, so the gate is
    /// reopened at the newest display epoch (a later raw callback still refuses the reopen).
    func saveDeskArrangement(_ key: String) async -> DeskArrangementResult {
        if let isTrusted, !isTrusted() { return .refused(SnapshotRefusal.accessibilityMissing.message) }
        // The gate status is read BEFORE the live layout: a display callback arriving while the layout
        // is read bumps the epoch past this snapshot and refuses the reopen below.
        let status = gate.status
        let live = liveLayout()
        guard DeskKey.make(for: live) == key else { return .notCurrentDesk }
        if !status.acceptsSnapshots {
            guard !status.isOpen, status.holds.isEmpty, status.reason == .layoutUnverified else {
                return .refused(gate.refusal.message)
            }
            // Reopen first: a refused reopen (a newer display callback) must leave the learned layout alone.
            guard gate.reopen(ifEpoch: status.displayEpoch) else { return .refused(gate.refusal.message) }
            await learnedStore.relearn(live, deskKey: key)
        }
        switch await snapshot(reason: .manual) {
        case .saved(let count), .savedAfterShrink(let count, _):
            var fields: [String: DiagnosticsValue] = ["windows": .int(count)]
            if let name = await learnedStore.name(forDesk: key) { fields["desk_name"] = .string(name) }
            diagnostics.record(DiagnosticsEvent(.snapshot, "desk-arrangement-saved", fields: fields))
            return .saved(windowCount: count)
        case .refused(let refusal): return .refused(refusal.message)
        case .notSaved(let message): return .refused(message)
        case .heldForConfirmation: return .failed("unconfirmed shrink on a manual save")
        case .failed(let message): return .failed(message)
        }
    }
}
