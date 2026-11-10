// SystemWakeObserver.swift
// Remembers when the Mac last woke so a display change right after a wake is labeled `wake` instead
// of `display-change` (a wake re-enumerates displays and looks exactly like a re-dock otherwise).
// Sleep and wake events are also written to the diagnostics diary.
// NSWorkspace posts these notifications on its own notification center, not the default one.
//
// Snapshot hold: while the screens are asleep (or the session is locked) AX cannot see other
// apps' windows, so captures shrink to almost nothing. On screensDidSleep this observer sets the
// `.screensAsleep` hold on SnapshotGate. On screensDidWake it polls the session-readiness probe (the
// same AX-join predicate the capture guard uses) with a bounded backoff and clears the hold once it
// passes, or after the bound so an edge case cannot keep snapshots off forever. Clearing the hold
// never reopens a display-change close; AutomationController stays the only reopener of those.
// A system wake alone never starts the check: the screens can stay asleep after it (dark wake), and
// the bound must not run out while they are.
//
// Lock signals are ADDITIVE ONLY: "com.apple.screenIsLocked" / "com.apple.screenIsUnlocked" are
// undocumented distributed notifications [UNVERIFIED on macOS 27]. A lock only sets the hold earlier;
// an unlock only starts the readiness check sooner, and only while the screens are awake. Neither is
// ever the sole condition for clearing.

import AppKit
import CoreGraphics
import Foundation
import Synchronization

/// What AutomationController needs from the wake tracker.
protocol WakeTracking: Sendable {
    /// Trigger for a display change that just closed the gate.
    func triggerForDisplayChange() -> CycleTrigger
}

/// "Can other apps' windows be read right now?" Implemented live with the capture's AX-join check.
protocol SessionReadinessProbing: Sendable {
    func isSessionReady() async -> Bool
}

/// Ready when the AX join is not collapsed: no other-app candidate windows, or at least one joined.
struct LiveSessionReadinessProbe: SessionReadinessProbing {
    var windowList: WindowListProviding = LiveWindowListProvider()
    var axProbe: AXWindowProbing = LiveAXWindowProbe()
    var ownerPID: Int32 = getpid()

    func isSessionReady() async -> Bool {
        let ownPID = ownerPID
        let candidates = windowList.windowList().filter { WindowCapturer.isCandidate($0, excludingOwnerPID: ownPID) }
        var axStates: [UInt32: AXWindowState] = [:]
        for pid in Set(candidates.map(\.ownerPID)).sorted() {
            axStates.merge(axProbe.probe(pid: pid).states) { _, new in new }
            if !axStates.isEmpty { break }  // one joined window is enough to trust the join
        }
        return !WindowCapturer.axJoinCollapsed(candidates: candidates, axStates: axStates, ownerPID: ownPID)
    }
}

/// Lock hint for the trail only. [UNVERIFIED] "CGSSessionScreenIsLocked" is an undocumented
/// CGSessionCopyCurrentDictionary key: absent while unlocked (verified 2026-11-08), assumed true while
/// locked (community usage). Recorded so the next lock confirms it; never used to decide anything.
enum SessionLockHint {
    static func isLocked() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as NSDictionary? else { return nil }
        return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }
}

/// Bounded backoff wait for session readiness, shared by the snapshot hold and the wake-cycle hold.
enum SessionReadiness {
    struct Schedule: Sendable {
        /// Delay before each re-check; the last value repeats.
        var delays: [Duration]
        /// Give up waiting after this much (virtual) time.
        var bound: Duration

        static let standard = Schedule(
            delays: [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30)],
            bound: .seconds(600)
        )
    }

    enum Result: String, Sendable {
        case ready, bounded, cancelled
    }

    struct Outcome: Sendable {
        let result: Result
        let waited: Duration
    }

    static func wait(probe: SessionReadinessProbing, clock: AppClock, schedule: Schedule) async -> Outcome {
        var waited: Duration = .zero
        var attempt = 0
        while !Task.isCancelled {
            if await probe.isSessionReady() { return Outcome(result: .ready, waited: waited) }
            if waited >= schedule.bound { return Outcome(result: .bounded, waited: waited) }
            let step = schedule.delays.isEmpty
                ? schedule.bound : schedule.delays[min(attempt, schedule.delays.count - 1)]
            let delay = min(step, schedule.bound - waited)
            do { try await clock.sleep(for: delay) } catch { break }
            waited += delay
            attempt += 1
        }
        return Outcome(result: .cancelled, waited: waited)
    }
}

final class SystemWakeObserver: WakeTracking, Sendable {
    /// A display change within this long after a wake is attributed to the wake (planner interpretation).
    static let wakeAttributionWindow: Duration = .seconds(10)

    private static let lockedNotification = Notification.Name("com.apple.screenIsLocked")
    private static let unlockedNotification = Notification.Name("com.apple.screenIsUnlocked")

    private struct State {
        var lastWake: Date?
        var tokens: [any NSObjectProtocol] = []
        var distributedTokens: [any NSObjectProtocol] = []
        /// Bumped by every hold set; a resume started for an older hold never clears a newer one.
        var holdGeneration: UInt64 = 0
        var resumeTask: Task<Void, Never>?
        /// False between screensDidSleep and screensDidWake. Only awake screens may start the clear.
        var screensAwake = true
        var onSessionReady: (@Sendable () async -> Void)?
    }

    private let state = Mutex(State())
    private let now: @Sendable () -> Date
    private let diagnostics: DiagnosticsRecording
    private let window: TimeInterval
    private let gate: SnapshotGate?
    private let readiness: SessionReadinessProbing?
    private let clock: AppClock
    private let schedule: SessionReadiness.Schedule

    /// - Parameters:
    ///   - gate: receives the `.screensAsleep` hold. Nil = attribution and diary only (tests).
    ///   - readiness: decides when the hold may clear after a wake. Nil = never set a hold.
    init(
        now: @escaping @Sendable () -> Date = { Date() },
        diagnostics: DiagnosticsRecording = DiagnosticsLog.shared,
        attributionWindow: Duration = SystemWakeObserver.wakeAttributionWindow,
        gate: SnapshotGate? = nil,
        readiness: SessionReadinessProbing? = nil,
        clock: AppClock = SystemClock(),
        schedule: SessionReadiness.Schedule = .standard
    ) {
        self.now = now
        self.diagnostics = diagnostics
        let parts = attributionWindow.components
        self.window = TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
        self.gate = readiness == nil ? nil : gate
        self.readiness = readiness
        self.clock = clock
        self.schedule = schedule
    }

    deinit {
        let (tokens, distributed, task) = state.withLock { ($0.tokens, $0.distributedTokens, $0.resumeTask) }
        for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        for token in distributed { DistributedNotificationCenter.default().removeObserver(token) }
        task?.cancel()
    }

    /// Called after the hold clears (ready or bounded), e.g. to resume a wake cycle held for the session.
    func setSessionReadyHandler(_ handler: @escaping @Sendable () async -> Void) {
        state.withLock { $0.onSessionReady = handler }
    }

    /// Subscribes to NSWorkspace sleep/wake, screens sleep/wake and the lock hints (idempotent).
    func start() {
        let center = NSWorkspace.shared.notificationCenter
        let subscriptions: [(Notification.Name, SleepWakeSignal)] = [
            (NSWorkspace.willSleepNotification, .systemSleep),
            (NSWorkspace.didWakeNotification, .systemWake),
            (NSWorkspace.screensDidSleepNotification, .screensSleep),
            (NSWorkspace.screensDidWakeNotification, .screensWake)
        ]
        let lockHints: [(Notification.Name, SleepWakeSignal)] = [
            (Self.lockedNotification, .sessionLocked),
            (Self.unlockedNotification, .sessionUnlocked)
        ]
        let distributed = DistributedNotificationCenter.default()
        state.withLock { st in
            guard st.tokens.isEmpty else { return }
            for (name, signal) in subscriptions {
                st.tokens.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                    self?.note(signal)
                })
            }
            for (name, signal) in lockHints {
                let token = distributed.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                    self?.note(signal)
                }
                st.distributedTokens.append(token)
            }
        }
    }

    /// Records a sleep/wake signal. Internal so tests can drive it without NSWorkspace.
    func note(_ signal: SleepWakeSignal) {
        if signal == .systemWake || signal == .screensWake {
            let stamp = now()
            state.withLock { $0.lastWake = stamp }
        }
        diagnostics.record(.sleepWake(signal))
        switch signal {
        case .screensSleep:
            state.withLock { $0.screensAwake = false }
            beginHold(signal)
        case .sessionLocked:
            beginHold(signal)
        case .screensWake:
            state.withLock { $0.screensAwake = true }
            resumeWhenReady(signal)
        case .sessionUnlocked:
            if state.withLock({ $0.screensAwake }) { resumeWhenReady(signal) }
        case .systemSleep, .systemWake:
            break  // a system wake can leave the screens asleep; screensDidWake starts the check
        }
    }

    func triggerForDisplayChange() -> CycleTrigger {
        let wake = state.withLock { $0.lastWake }
        guard let wake else { return .displayChange }
        let elapsed = now().timeIntervalSince(wake)
        return elapsed >= 0 && elapsed <= window ? .wake : .displayChange
    }

    /// Test seam: waits for the readiness check started by the last wake signal.
    func waitForResume() async {
        let task = state.withLock { $0.resumeTask }
        await task?.value
    }

    // MARK: Hold

    private func beginHold(_ signal: SleepWakeSignal) {
        guard let gate else { return }
        let added = state.withLock { st -> Bool in
            st.resumeTask?.cancel()
            st.resumeTask = nil
            st.holdGeneration &+= 1
            return gate.setHold(.screensAsleep)
        }
        diagnostics.record(.holdSet(signal: signal, added: added))
    }

    private func resumeWhenReady(_ signal: SleepWakeSignal) {
        guard let gate, let readiness else { return }
        let clock = clock, schedule = schedule
        state.withLock { st in
            guard gate.holds.contains(.screensAsleep) else { return }
            st.resumeTask?.cancel()
            let generation = st.holdGeneration
            st.resumeTask = Task { [weak self] in
                let outcome = await SessionReadiness.wait(probe: readiness, clock: clock, schedule: schedule)
                guard outcome.result != .cancelled, !Task.isCancelled else { return }
                await self?.finishHold(outcome, generation: generation, after: signal)
            }
        }
    }

    private func finishHold(_ outcome: SessionReadiness.Outcome, generation: UInt64,
                            after signal: SleepWakeSignal) async {
        guard let gate else { return }
        let cleared = state.withLock { st -> Bool in
            guard st.holdGeneration == generation else { return false }
            st.resumeTask = nil
            return gate.clearHold(.screensAsleep)
        }
        guard cleared else { return }
        diagnostics.record(.holdCleared(signal: signal, outcome: outcome))
        let handler = state.withLock { $0.onSessionReady }
        await handler?()
    }
}

enum SleepWakeSignal: String, Sendable {
    case systemSleep = "system-sleep"
    case systemWake = "system-wake"
    case screensSleep = "screens-sleep"
    case screensWake = "screens-wake"
    /// Lock hints [UNVERIFIED]: additive only.
    case sessionLocked = "session-locked"
    case sessionUnlocked = "session-unlocked"
}

private extension DiagnosticsEvent {
    static func holdSet(signal: SleepWakeSignal, added: Bool) -> DiagnosticsEvent {
        var fields: [String: DiagnosticsValue] = [
            "hold": .code(SnapshotHold.screensAsleep), "signal": .code(signal), "added": .bool(added)
        ]
        if let locked = SessionLockHint.isLocked() { fields["lockedHint"] = .bool(locked) }
        return DiagnosticsEvent(.gate, "snapshot-hold-set", fields: fields)
    }

    static func holdCleared(signal: SleepWakeSignal, outcome: SessionReadiness.Outcome) -> DiagnosticsEvent {
        let parts = outcome.waited.components
        let waitedMs = Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
        var fields: [String: DiagnosticsValue] = [
            "hold": .code(SnapshotHold.screensAsleep), "signal": .code(signal),
            "result": .code(outcome.result), "waitedMs": .int(waitedMs)
        ]
        if let locked = SessionLockHint.isLocked() { fields["lockedHint"] = .bool(locked) }
        return DiagnosticsEvent(.gate, "snapshot-hold-cleared", fields: fields)
    }
}
