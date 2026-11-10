// AutomationController.swift
// Hands-off flow after a replug (TECHNICAL_SPEC v1.1):
//   raw callback closes SnapshotGate (DisplayMonitor, synchronous) -> settled display event -> working
//   icon -> wait until the docked set (learned panel serials) is present -> restore delay (3 s) -> poll
//   the serial map until stable -> RestoreCoordinator.restoreNow (detect swap -> fix monitors -> restore
//   windows) -> reopen SnapshotGate + publish the result.
// This actor is the ONLY code that reopens the gate. It does so atomically with the "no follow-up
// pending" decision (no suspension between them) and only at the newest epoch it has ingested, so a
// callback still inside the debounce keeps the gate closed.
// Single-flight: a change during an in-flight cycle restarts the settle wait (before the restore) or
// queues exactly one follow-up cycle (during the restore); the gate stays closed across both cycles.
// Self-triggered changes never arrive here because DisplayMonitor suppresses them while MonitorFixer
// runs.
// Session hold: right before restoring, the cycle checks that other apps' windows can be read
// (the capture's AX-join predicate). At the lock screen they cannot, and a restore would mark every
// window ax-unreachable, so the cycle ends `.hold(.sessionNotReady)` with the gate still closed and
// resumes (same context) once readiness passes, polled with a bounded backoff. After the bound it
// restores anyway so the gate cannot stay closed forever.
// Quiet wake: the controller hands restoreNow the facts only it knows (a display was added
// or removed in this cycle's events; the cycle resumed only because the session hold hit its bound).
// RestoreCoordinator decides with QuietWakePolicy; a `.quietWake` outcome reopens like a restore.

import Foundation
import os

// MARK: - Seams

/// Each operation exists with and without a `CycleContext`; every conformer implements at least one
/// (the defaults forward to each other). Fakes written before cycle contexts keep the no-context form.
protocol AutoRestoring: Sendable {
    func restoreNow() async -> RestoreOutcome
    func fixMonitors() async -> RestoreOutcome
    func restoreNow(context: CycleContext) async -> RestoreOutcome
    func fixMonitors(context: CycleContext) async -> RestoreOutcome
}

extension AutoRestoring {
    func restoreNow() async -> RestoreOutcome { await restoreNow(context: .manual()) }
    func fixMonitors() async -> RestoreOutcome { await fixMonitors(context: .manual()) }
    func restoreNow(context: CycleContext) async -> RestoreOutcome { await restoreNow() }
    func fixMonitors(context: CycleContext) async -> RestoreOutcome { await fixMonitors() }
}

extension RestoreCoordinator: AutoRestoring {}

/// Snapshot side of automation (implemented by `SnapshotCoordinator`): the per-desk learned layout
/// lookup for the docked-set rule and the scheduler tick. Pausing is NOT here: it is the shared `SnapshotGate`.
protocol SnapshotPauseControlling: Sendable {
    func deskLookup(live: MonitorLayout) async -> DeskLookup
    func runScheduledSnapshot() async
    /// Registers the live desk when it is unseen and returns the new-desk event (nil otherwise).
    func registerNewDesk(live: MonitorLayout) async -> NewDeskEvent?
}

extension SnapshotPauseControlling {
    func registerNewDesk(live: MonitorLayout) async -> NewDeskEvent? { nil }
}

extension SnapshotCoordinator: SnapshotPauseControlling {}

/// Publishes automation progress to the menu (working icon, last result, attention icon).
protocol AutomationStatusReporting: Sendable {
    func automationDidBegin() async
    /// `outcome` nil means the cycle ended without running a restore.
    func automationDidFinish(outcome: RestoreOutcome?) async
    /// Same, with the cycle that produced it. Defaults forward to the outcome-only form.
    func automationDidFinish(outcome: RestoreOutcome?, context: CycleContext) async
}

extension AutomationStatusReporting {
    func automationDidFinish(outcome: RestoreOutcome?, context: CycleContext) async {
        await automationDidFinish(outcome: outcome)
    }
}

/// Posts the problem notification for a finished cycle (implemented by `ProblemNotifier`).
protocol ProblemNotifying: Sendable {
    func notify(context: CycleContext, outcome: RestoreOutcome) async
}

extension ProblemNotifier: ProblemNotifying {}

/// Wraps the menu reporter: the menu updates first, then an automatic cycle's outcome goes to the
/// notifier (which itself ignores manual runs and non-problems). Notification work runs off the
/// cycle so a macOS permission prompt can never hold the restore pipeline.
actor NotifyingAutomationStatus: AutomationStatusReporting {
    private let inner: AutomationStatusReporting
    private let notifier: ProblemNotifying
    private var pending: [Task<Void, Never>] = []

    init(inner: AutomationStatusReporting, notifier: ProblemNotifying) {
        self.inner = inner
        self.notifier = notifier
    }

    func automationDidBegin() async { await inner.automationDidBegin() }

    func automationDidFinish(outcome: RestoreOutcome?) async {
        await inner.automationDidFinish(outcome: outcome)
    }

    func automationDidFinish(outcome: RestoreOutcome?, context: CycleContext) async {
        await inner.automationDidFinish(outcome: outcome, context: context)
        guard let outcome else { return }
        let notifier = notifier
        pending.append(Task { await notifier.notify(context: context, outcome: outcome) })
    }

    /// Test seam: waits for every notification hand-off started so far.
    func waitForNotifications() async {
        let tasks = pending
        pending = []
        for task in tasks { await task.value }
    }
}

// MARK: - Controller

actor AutomationController {
    struct Timing: Sendable {
        /// Hard-coded by the snapshot file format.
        var restoreDelay: Duration = .seconds(3)
        var pollInterval: Duration = .seconds(1)
        /// Consecutive identical samples that count as "stable".
        var stableSamples = 2
        /// Upper bound on stability polling; proceeds with the latest layout after this.
        var maxStablePolls = 10
        /// Upper bound on waiting for the docked set to reappear.
        var maxDockedPolls = 30
    }

    /// How a cycle ended, as far as the gate is concerned.
    private enum CycleEnd: Equatable {
        /// Restore ran (success or failure) or the layout was verified: the gate may reopen.
        case reopen
        /// Keep the gate closed with this reason until the next event (or Accessibility returns).
        case hold(SnapshotRefusal)
    }

    private static let logger = Logger(subsystem: "com.productengineered.TotalRekall", category: "automation")

    nonisolated let gate: SnapshotGate
    private let events: AsyncStream<DisplayChangeEvent>
    private let pause: SnapshotPauseControlling
    private let restorer: AutoRestoring
    private let trust: AccessibilityTrustChecking
    private let status: AutomationStatusReporting
    private let liveLayout: @Sendable () -> MonitorLayout
    private let clock: AppClock
    private let timing: Timing
    private let scheduler: SnapshotScheduler
    private let wake: WakeTracking?
    private let now: @Sendable () -> Date
    private let diagnostics: DiagnosticsRecording
    /// New-desk event sink (named desks). Synchronous and non-blocking by contract: the receiver hops to
    /// the main actor itself, so a prompt that is never shown can never hold the cycle or the gate.
    private let onNewDesk: (@Sendable (NewDeskEvent) -> Void)?
    /// Called after a cycle's end reopened the gate (the whole display-change cycle, including any
    /// follow-up, is over). Same contract as `onNewDesk`: synchronous, non-blocking, hops itself.
    private let onGateReopened: (@Sendable () -> Void)?
    /// ID of the cycle currently running (events outside `runCycle` still carry it).
    private var activeCycleID: UUID?

    private var listener: Task<Void, Never>?
    private var cycle: Task<Void, Never>?
    private var changePending = false
    /// Newest gate epoch carried by an ingested display event.
    private var ingestedEpoch: UInt64 = 0
    /// Gate held closed because a change arrived while Accessibility was missing.
    private var heldForAccessibility = false
    /// Gate held closed because the session was not ready (e.g. still at the lock screen).
    private var heldForSession = false
    /// Polls readiness while `heldForSession`; cancelled by a new display event or stop().
    private var sessionWatch: Task<Void, Never>?
    /// Set when the session wait hit its bound: the resumed cycle restores without re-checking.
    private var bypassSessionCheck = false
    private let sessionReadiness: SessionReadinessProbing?
    private let sessionSchedule: SessionReadiness.Schedule
    /// The context of the cycle held for missing Accessibility or session readiness; resumed with the
    /// same trigger.
    private var heldContext: CycleContext?
    /// A display was added or removed in an event not yet handed to a restore. Taken (and cleared) when
    /// a cycle restores, so an event during that restore counts toward its follow-up; it survives held
    /// and dropped cycles (err toward not quiet).
    private var displaysAddedOrRemoved = false
    /// Trigger of the newest change that queued a follow-up cycle.
    private var pendingTrigger: CycleTrigger?
    /// Phase label for the gate's menu message; never decides openness.
    private var machine = SnapshotPauseStateMachine()
    private(set) var cyclesRun = 0

    init(
        events: AsyncStream<DisplayChangeEvent>,
        gate: SnapshotGate,
        pause: SnapshotPauseControlling,
        restorer: AutoRestoring,
        trust: AccessibilityTrustChecking,
        status: AutomationStatusReporting,
        liveLayout: @escaping @Sendable () -> MonitorLayout,
        clock: AppClock = SystemClock(),
        timing: Timing = Timing(),
        snapshotInterval: Duration = SnapshotScheduler.defaultInterval,
        wake: WakeTracking? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        diagnostics: DiagnosticsRecording = DiagnosticsLog.shared,
        sessionReadiness: SessionReadinessProbing? = nil,
        sessionSchedule: SessionReadiness.Schedule = .standard,
        onNewDesk: (@Sendable (NewDeskEvent) -> Void)? = nil,
        onGateReopened: (@Sendable () -> Void)? = nil
    ) {
        self.onNewDesk = onNewDesk
        self.onGateReopened = onGateReopened
        self.sessionReadiness = sessionReadiness
        self.sessionSchedule = sessionSchedule
        self.diagnostics = diagnostics
        self.wake = wake
        self.now = now
        self.events = events
        self.gate = gate
        self.pause = pause
        self.restorer = restorer
        self.trust = trust
        self.status = status
        self.liveLayout = liveLayout
        self.clock = clock
        self.timing = timing
        self.scheduler = SnapshotScheduler(
            clock: clock, interval: snapshotInterval, diagnostics: diagnostics
        ) { [pause] in
            await pause.runScheduledSnapshot()
        }
    }

    var pauseState: SnapshotPauseState { machine.state }

    // MARK: Lifecycle

    /// Subscribes to display events, runs the launch monitor check, then starts the scheduler
    /// (whose first tick is the launch snapshot).
    func start() {
        guard listener == nil else { return }
        let stream = events
        listener = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.receive(event)
            }
        }
        Task { [weak self] in
            await self?.launchCheck()
            await self?.scheduler.start()
        }
    }

    func stop() async {
        listener?.cancel()
        listener = nil
        cycle?.cancel()
        cycle = nil
        sessionWatch?.cancel()
        sessionWatch = nil
        await scheduler.stop()
    }

    /// Waits for the in-flight cycle (tests).
    func waitUntilIdle() async {
        await cycle?.value
    }

    /// Waits for the session-readiness watch of a held cycle (tests).
    func waitForSessionWatch() async {
        await sessionWatch?.value
    }

    // MARK: Events

    /// One settled display change. Starts a cycle, or folds into the one already running.
    /// Synchronous on the actor: the epoch and the follow-up flag are recorded before any suspension,
    /// so the reopen decision in `runCycles` can never miss this event.
    func receive(_ event: DisplayChangeEvent) {
        ingestedEpoch = max(ingestedEpoch, event.throughEpoch)
        if !event.added.isEmpty || !event.removed.isEmpty { displaysAddedOrRemoved = true }
        heldForAccessibility = false
        clearSessionHold()
        heldContext = nil
        transition(.displayCallback)
        startOrQueueCycle(trigger: wake?.triggerForDisplayChange() ?? .displayChange)
    }

    /// Accessibility trust changed. When a change was held for missing Accessibility, run the cycle
    /// now so the layout is fixed and verified before snapshots resume.
    func accessibilityChanged(trusted: Bool) {
        guard trusted, heldForAccessibility else { return }
        heldForAccessibility = false
        let resumed = heldContext
        heldContext = nil
        startOrQueueCycle(trigger: resumed?.trigger ?? .displayChange, resuming: resumed)
    }

    private func startOrQueueCycle(trigger: CycleTrigger, resuming: CycleContext? = nil) {
        if cycle != nil {
            changePending = true
            pendingTrigger = trigger
            diagnostics.record(.followUpQueued(cycleID: activeCycleID, trigger: trigger))
            return
        }
        let context = resuming ?? CycleContext(trigger: trigger, startedAt: now())
        cycle = Task { [weak self] in
            await self?.runCycles(first: context)
        }
    }

    private func transition(_ event: SnapshotPauseEvent) {
        machine.handle(event)
        if let reason = machine.pauseRefusal { gate.relabel(reason) }
    }

    // MARK: Launch

    /// Monitor check at launch, before the first snapshot: fixes a swap left from a prior session.
    /// Only a real fix (or a failure) is published; a clean check leaves the menu untouched.
    private func launchCheck() async {
        guard trust.isProcessTrusted() else { return }
        let context = CycleContext(trigger: .launch, startedAt: now())
        let outcome = await restorer.fixMonitors(context: context)
        switch outcome {
        case .monitorsFixed(.unverified, _), .monitorsFixed(.failed, _), .failed:
            await status.automationDidFinish(outcome: outcome, context: context)
        default:
            break  // clean check or verified fix: don't claim a restore at launch
        }
    }

    // MARK: Cycle

    private func runCycles(first: CycleContext) async {
        var context = first
        while true {
            changePending = false
            pendingTrigger = nil
            let end = await runCycle(context)
            // From here to `cycle = nil` there is NO suspension point: the follow-up check, the
            // reopen and the hand-back are atomic with respect to `receive`.
            if changePending && !Task.isCancelled {
                // A change arrived during this cycle: keep the gate closed and run the follow-up.
                endRestorePhase()
                transition(.displayCallback)
                // The follow-up is a new cycle: new ID, and the trigger of the change that queued it.
                context = CycleContext(trigger: pendingTrigger ?? context.trigger, startedAt: now())
                continue
            }
            finish(end, context: context)
            cycle = nil
            return
        }
    }

    /// Applies a cycle's end to the gate. Synchronous.
    private func finish(_ end: CycleEnd, context: CycleContext) {
        switch end {
        case .reopen where !Task.isCancelled:
            // Same epoch the gate-closed record carried (the close that began this closed period).
            let closedEpoch = gate.closedEpoch
            if gate.reopen(ifEpoch: ingestedEpoch) {
                endRestorePhase()
                diagnostics.record(.gateReopened(cycleID: context.cycleID, epoch: closedEpoch))
                onGateReopened?()
            } else {
                // A raw callback is still in the debounce; its event starts the next cycle.
                endRestorePhase()
                transition(.displayCallback)
                diagnostics.record(.gateHeld(cycleID: context.cycleID, reason: "newer-callback-pending"))
            }
        case .reopen:
            break  // cancelled (stop): stay closed
        case .hold(let reason):
            endRestorePhase()
            transition(.displayCallback)
            gate.relabel(reason)
            heldForAccessibility = reason == .accessibilityMissing
            heldForSession = reason == .sessionNotReady
            heldContext = heldForAccessibility || heldForSession ? context : nil
            diagnostics.record(.gateHeld(cycleID: context.cycleID, reason: reason.automationTrailCode))
            if heldForSession { startSessionWatch() }
        }
    }

    /// Moves the label machine out of the restore phase (to idle) without touching the gate.
    private func endRestorePhase() {
        machine.handle(.restoreFinished(success: true))
    }

    private func runCycle(_ context: CycleContext) async -> CycleEnd {
        cyclesRun += 1
        activeCycleID = context.cycleID
        diagnostics.record(.cycleStarted(context, epoch: ingestedEpoch))
        guard trust.isProcessTrusted() else {
            // Warning shows in the menu instead; nothing to automate. The gate stays closed: the layout
            // may be swapped and must not be learned until a cycle runs with Accessibility.
            recordCycleFinished(context, outcome: nil, note: "accessibility-missing")
            return .hold(.accessibilityMissing)
        }
        await status.automationDidBegin()
        let waited = await waitForStableDockedLayout(context)
        diagnostics.record(.dockedSetWait(cycleID: context.cycleID, stable: waited))
        guard waited else {
            // Cancelled, or the docked set never came back (laptop-only): stay closed; the next
            // display event starts a fresh cycle.
            await status.automationDidFinish(outcome: nil, context: context)
            recordCycleFinished(context, outcome: nil, note: "docked-set-absent")
            return .hold(.dockedSetAbsent)
        }
        let resumedByHoldBound = bypassSessionCheck
        if await !sessionReadyForRestore() {
            // At the lock screen a restore would find every window ax-unreachable: hold, gate closed.
            await status.automationDidFinish(outcome: nil, context: context)
            recordCycleFinished(context, outcome: nil, note: "session-not-ready")
            return .hold(.sessionNotReady)
        }
        transition(.displaySettled(needsRestore: true))
        transition(.restoreStarted)
        let restoring = context.with(quietWake: takeQuietWakeEligibility(resumedByHoldBound: resumedByHoldBound))
        let outcome = await restorer.restoreNow(context: restoring)
        if restoring.quietWake?.displaysAddedOrRemoved == true, !Self.wroteRestoreLog(outcome) {
            displaysAddedOrRemoved = true  // no restore log written: the next cycle still counts these events
        }
        await status.automationDidFinish(outcome: outcome, context: restoring)
        recordCycleFinished(restoring, outcome: outcome, note: nil)
        return await cycleEnd(for: outcome)
    }

    /// Dropped, refused, failed and no-snapshot cycles write no restore log.
    private static func wroteRestoreLog(_ outcome: RestoreOutcome) -> Bool {
        switch outcome {
        case .restored, .quietWake, .monitorsFixed: true
        case .refusedNoAccessibility, .droppedInFlight, .noSnapshot, .failed: false
        }
    }

    /// Synchronous with the restore call: events after this point belong to the follow-up cycle.
    private func takeQuietWakeEligibility(resumedByHoldBound: Bool) -> QuietWakeEligibility {
        let eligibility = QuietWakeEligibility(displaysAddedOrRemoved: displaysAddedOrRemoved,
                                               resumedByHoldBound: resumedByHoldBound)
        displaysAddedOrRemoved = false
        return eligibility
    }

#if DEBUG
    /// Debug seam (-TRSimulateProblemNotification): pushes a sample outcome through the same reporter
    /// calls a real cycle makes, so the menu's attention state and the notification both follow the
    /// real path. Never touches the restorer, the gate or any window.
    func simulateFinishedCycle(outcome: RestoreOutcome, trigger: CycleTrigger = .displayChange) async {
        let context = CycleContext(trigger: trigger, startedAt: now())
        diagnostics.record(.cycleStarted(context, epoch: ingestedEpoch))
        await status.automationDidBegin()
        await status.automationDidFinish(outcome: outcome, context: context)
        recordCycleFinished(context, outcome: outcome, note: "simulated")
    }
#endif

    private func recordCycleFinished(_ context: CycleContext, outcome: RestoreOutcome?, note: String?) {
        let elapsed = now().timeIntervalSince(context.startedAt)
        diagnostics.record(.cycleFinished(cycleID: context.cycleID, outcome: outcome, note: note,
                                          durationMs: Int(max(0, elapsed) * 1000)))
    }

    private func cycleEnd(for outcome: RestoreOutcome) async -> CycleEnd {
        switch outcome {
        case .restored, .quietWake, .monitorsFixed, .failed:
            return .reopen  // restore finished, success or failure: snapshots resume
        case .refusedNoAccessibility:
            return .hold(.accessibilityMissing)
        case .droppedInFlight:
            changePending = true  // a manual run owns the pipeline; retry once it is done
            return .hold(.restoring)
        case .noSnapshot:
            // Nothing to restore. A new desk is a first run: reopen so the next snapshot learns it.
            // A known desk resumes only if the live layout is verified against that desk's own layout.
            let live = liveLayout()
            let lookup = await pause.deskLookup(live: live)
            switch lookup.match {
            case .newDesk:
                // Register at event time and announce once; fire and forget, then reopen regardless.
                if let event = await pause.registerNewDesk(live: live) {
                    diagnostics.record(DiagnosticsEvent(.automation, "new-desk", fields: [:]))
                    onNewDesk?(event)
                }
                return .reopen
            case .subsetOfKnownDesk: return .hold(.dockedSetAbsent)
            case .knownDesk:
                let verified = SwapDetector.detect(learned: lookup.layout, live: live) == .correct
                return verified ? .reopen : .hold(.layoutUnverified)
            }
        }
    }
}

// MARK: - Settle wait

extension AutomationController {
    /// False when cancelled or when the docked set is still absent after the bounded wait.
    private func waitForStableDockedLayout(_ context: CycleContext) async -> Bool {
        var dockedPolls = 0
        while !Task.isCancelled {
            if await !dockedSetPresent() {
                dockedPolls += 1
                if dockedPolls >= timing.maxDockedPolls { return false }
                guard await sleep(timing.pollInterval) else { return false }
                changePending = false  // we are re-evaluating from scratch anyway
                continue
            }
            guard await sleep(timing.restoreDelay) else { return false }
            if changePending {  // layout moved again during the delay: start over
                changePending = false
                diagnostics.record(.settleRestarted(cycleID: context.cycleID, reason: "change-during-delay"))
                continue
            }
            switch await pollUntilStable() {
            case .stable: return true
            case .restart:
                diagnostics.record(.settleRestarted(cycleID: context.cycleID, reason: "layout-unstable"))
                continue
            case .cancelled: return false
            }
        }
        return false
    }

    private enum StableResult { case stable, restart, cancelled }

    private func pollUntilStable() async -> StableResult {
        var previous = liveLayout()
        var matching = 1
        var polls = 0
        while matching < timing.stableSamples && polls < timing.maxStablePolls {
            guard await sleep(timing.pollInterval) else { return .cancelled }
            if changePending {
                changePending = false
                return .restart
            }
            polls += 1
            let current = liveLayout()
            if current == previous {
                matching += 1
            } else {
                matching = 1
                previous = current
            }
        }
        if await !dockedSetPresent() { return .restart }
        return .stable
    }

    private func dockedSetPresent() async -> Bool {
        await pause.deskLookup(live: liveLayout()).match != .subsetOfKnownDesk
    }

    private func sleep(_ duration: Duration) async -> Bool {
        do {
            try await clock.sleep(for: duration)
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}

// MARK: - Session hold

extension AutomationController {
    /// The session may be usable now (the screens hold cleared, or an unlock hint). Resumes a cycle held
    /// for the session if the readiness probe agrees.
    func sessionMayBeReady() async {
        guard heldForSession, let sessionReadiness else { return }
        guard await sessionReadiness.isSessionReady() else { return }
        resumeHeldSession(bounded: false)
    }

    private func resumeHeldSession(bounded: Bool) {
        guard heldForSession else { return }
        let resumed = heldContext
        clearSessionHold()
        heldContext = nil
        bypassSessionCheck = bounded
        diagnostics.record(.sessionResumed(cycleID: resumed?.cycleID, bounded: bounded))
        startOrQueueCycle(trigger: resumed?.trigger ?? .displayChange, resuming: resumed)
    }

    private func clearSessionHold() {
        heldForSession = false
        bypassSessionCheck = false
        sessionWatch?.cancel()
        sessionWatch = nil
    }

    private func startSessionWatch() {
        sessionWatch?.cancel()
        guard let sessionReadiness else { return }
        let clock = clock, schedule = sessionSchedule
        sessionWatch = Task { [weak self] in
            let outcome = await SessionReadiness.wait(probe: sessionReadiness, clock: clock, schedule: schedule)
            guard outcome.result != .cancelled, !Task.isCancelled else { return }
            await self?.resumeHeldSession(bounded: outcome.result == .bounded)
        }
    }

    /// True when no probe is wired, the bounded wait already ran out, or other apps' windows can be read.
    private func sessionReadyForRestore() async -> Bool {
        if bypassSessionCheck {
            bypassSessionCheck = false
            return true
        }
        guard let sessionReadiness else { return true }
        return await sessionReadiness.isSessionReady()
    }
}

// MARK: - Menu adapter

/// Drives the working icon and publishes outcomes through `MenuBarViewModel.apply`.
@MainActor
final class MenuAutomationStatus: AutomationStatusReporting {
    private weak var viewModel: MenuBarViewModel?
    private var previousState: AppState = .idle

    init(viewModel: MenuBarViewModel) {
        self.viewModel = viewModel
    }

    func automationDidBegin() async {
        guard let viewModel else { return }
        if viewModel.state != .working { previousState = viewModel.state }
        viewModel.state = .working
    }

    func automationDidFinish(outcome: RestoreOutcome?) async {
        guard let viewModel else { return }
        if let outcome {
            viewModel.apply(outcome, previousState: previousState)
        } else if viewModel.state == .working {
            viewModel.state = previousState
        }
    }
}

// MARK: - Diagnostics events

private extension SnapshotRefusal {
    var automationTrailCode: String {
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

private extension RestoreOutcome {
    var trailKind: String {
        switch self {
        case .refusedNoAccessibility: "refused-no-accessibility"
        case .droppedInFlight: "dropped-in-flight"
        case .noSnapshot: "no-snapshot"
        case .restored: "restored"
        case .quietWake: "quiet"
        case .monitorsFixed: "monitors-fixed"
        case .failed: "failed"
        }
    }
}

private extension DiagnosticsEvent {
    static func cycleStarted(_ context: CycleContext, epoch: UInt64) -> DiagnosticsEvent {
        DiagnosticsEvent(.automation, "cycle-started", cycleID: context.cycleID, fields: [
            "trigger": .code(context.trigger),
            "epoch": .int(Int(truncatingIfNeeded: epoch))
        ])
    }

    static func dockedSetWait(cycleID: UUID, stable: Bool) -> DiagnosticsEvent {
        DiagnosticsEvent(.automation, "docked-set-wait", cycleID: cycleID,
                         fields: ["result": .string(stable ? "stable" : "absent-or-cancelled")])
    }

    static func settleRestarted(cycleID: UUID, reason: String) -> DiagnosticsEvent {
        DiagnosticsEvent(.automation, "settle-restarted", cycleID: cycleID, fields: ["reason": .string(reason)])
    }

    static func followUpQueued(cycleID: UUID?, trigger: CycleTrigger) -> DiagnosticsEvent {
        DiagnosticsEvent(.automation, "follow-up-queued", cycleID: cycleID, fields: ["trigger": .code(trigger)])
    }

    static func cycleFinished(cycleID: UUID, outcome: RestoreOutcome?, note: String?,
                              durationMs: Int) -> DiagnosticsEvent {
        var fields: [String: DiagnosticsValue] = [
            "outcome": .string(outcome?.trailKind ?? note ?? "none"),
            "durationMs": .int(durationMs)
        ]
        if case .restored(let summary) = outcome {
            fields["restored"] = .int(summary.restored)
            fields["total"] = .int(summary.total)
            fields["needsAttention"] = .bool(summary.needsAttention)
        } else if case .quietWake(let summary) = outcome {
            fields["restored"] = .int(summary.restored)
            fields["total"] = .int(summary.total)
            fields["needsAttention"] = .bool(false)
        } else if let outcome {
            switch outcome {
            case .failed: fields["needsAttention"] = .bool(true)
            case .monitorsFixed(let fix, _): fields["needsAttention"] = .bool(fix.setsAttention)
            default: fields["needsAttention"] = .bool(false)
            }
        }
        return DiagnosticsEvent(.automation, "cycle-finished", cycleID: cycleID, fields: fields)
    }

    static func gateReopened(cycleID: UUID, epoch: UInt64) -> DiagnosticsEvent {
        DiagnosticsEvent(.gate, "gate-reopened", cycleID: cycleID,
                         fields: ["epoch": .int(Int(truncatingIfNeeded: epoch))])
    }

    static func sessionResumed(cycleID: UUID?, bounded: Bool) -> DiagnosticsEvent {
        DiagnosticsEvent(.automation, "session-resumed", cycleID: cycleID,
                         fields: ["result": .string(bounded ? "bounded" : "ready")])
    }

    static func gateHeld(cycleID: UUID, reason: String) -> DiagnosticsEvent {
        DiagnosticsEvent(.gate, "gate-held", cycleID: cycleID, fields: ["reason": .string(reason)])
    }
}
