import AppKit
import CoreGraphics
import Synchronization

// MARK: - Event types

/// One raw signal from CoreGraphics (or the screen-parameters notification), before debouncing.
struct RawDisplayEvent: Sendable, Equatable {
    enum Source: Sendable, Equatable {
        case reconfigurationCallback
        case screenParameters
    }

    var displayID: UInt32
    /// `CGDisplayChangeSummaryFlags.rawValue`.
    var flags: UInt32
    var vendorID: UInt32
    var source: Source
    /// SnapshotGate epoch assigned when this event closed the gate (set by `DisplayMonitor.receive`).
    var epoch: UInt64 = 0

    static func screenParametersChanged() -> RawDisplayEvent {
        RawDisplayEvent(displayID: 0, flags: 0, vendorID: 0, source: .screenParameters)
    }

    var summaryFlags: CGDisplayChangeSummaryFlags { CGDisplayChangeSummaryFlags(rawValue: flags) }
}

/// One settled display change: everything that happened in a burst of callbacks, emitted once
/// after the debounce window passes with no further activity.
struct DisplayChangeEvent: Sendable, Equatable {
    var added: Set<UInt32> = []
    var removed: Set<UInt32> = []
    var moved: Set<UInt32> = []
    /// Raw callbacks/notifications folded into this event.
    var rawEventCount = 0
    /// Newest SnapshotGate epoch folded into this event. AutomationController may reopen the gate
    /// only at the newest epoch it has ingested, so a callback still in the debounce keeps it closed.
    var throughEpoch: UInt64 = 0
}

// MARK: - Shared synchronous state

/// Lock-guarded debounce state read synchronously from the CG callback (main thread).
/// `inProgress` is debounce bookkeeping only; the snapshot pause is `SnapshotGate`.
/// Suppression MUST be synchronous: reconfiguration callbacks fire inside
/// CGCompleteDisplayConfiguration, before `endSelfChange()` returns.
final class DisplayMonitorGate: Sendable {
    private struct State {
        var depth = 0
        var inProgress = false
    }

    private let state = Mutex(State())

    var suppressionDepth: Int { state.withLock { $0.depth } }
    var isChangeInProgress: Bool { state.withLock { $0.inProgress } }

    func beginSuppression() { state.withLock { $0.depth += 1 } }
    func endSuppression() { state.withLock { $0.depth = max(0, $0.depth - 1) } }
    func setInProgress(_ value: Bool) { state.withLock { $0.inProgress = value } }

    /// Returns false while suppressed; otherwise marks a change in progress and returns true.
    func admit() -> Bool {
        state.withLock { state in
            if state.depth > 0 { return false }
            state.inProgress = true
            return true
        }
    }
}

// MARK: - C callback bridge

private final class DisplayCallbackBox: Sendable {
    let receiver: @Sendable (RawDisplayEvent) -> Bool
    init(_ receiver: @escaping @Sendable (RawDisplayEvent) -> Bool) { self.receiver = receiver }
}

private let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { displayID, flags, context in
    guard let context else { return }
    let box = Unmanaged<DisplayCallbackBox>.fromOpaque(context).takeUnretainedValue()
    _ = box.receiver(RawDisplayEvent(displayID: displayID,
                                     flags: flags.rawValue,
                                     vendorID: CGDisplayVendorNumber(displayID),
                                     source: .reconfigurationCallback))
}

/// Owns the CG callback registration and the screen-parameters observer. Main-actor only:
/// the callback is delivered solely in an NSApplication context, on the main thread.
/// The retained callback context is balanced by exactly one release in `invalidate()`.
@MainActor
final class DisplayReconfigurationRegistration {
    private let context: Unmanaged<DisplayCallbackBox>
    private var observer: NSObjectProtocol?
    private var isActive = true

    init(receiver: @escaping @Sendable (RawDisplayEvent) -> Bool) {
        context = Unmanaged.passRetained(DisplayCallbackBox(receiver))
        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, context.toOpaque())
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            _ = receiver(.screenParametersChanged())
        }
    }

    func invalidate() {
        guard isActive else { return }
        isActive = false
        CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, context.toOpaque())
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        context.release()
    }
}

// MARK: - DisplayMonitor

/// Debounces CoreGraphics display-reconfiguration bursts into single `DisplayChangeEvent`s.
///
/// Pipeline: callback (main thread) -> `receive` (sync suppression + vendor guard + SnapshotGate
/// close) -> ordered raw stream -> `ingest` (actor) -> debounce on the injected `AppClock` -> `events`.
/// The monitor only ever CLOSES the snapshot gate; AutomationController reopens it.
actor DisplayMonitor: SelfChangeSuppressor {
    /// Suppressed self-change callbacks counted since the last `endSelfChange` flush.
    private let suppressedCount = Mutex(0)
    private let diagnostics: DiagnosticsRecording
    /// Assumed from observation (observed max inter-event gap: 897 ms).
    static let defaultDebounce: Duration = .milliseconds(1500)

    nonisolated let events: AsyncStream<DisplayChangeEvent>

    private let eventContinuation: AsyncStream<DisplayChangeEvent>.Continuation
    private let rawStream: AsyncStream<RawDisplayEvent>
    private let rawContinuation: AsyncStream<RawDisplayEvent>.Continuation
    private let gate = DisplayMonitorGate()
    nonisolated let snapshotGate: SnapshotGate
    private let debounce: Duration
    private let clock: AppClock

    private var pending = DisplayChangeEvent()
    private var generation = 0
    private var settleTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var registration: DisplayReconfigurationRegistration?
    private(set) var ingestedCount = 0

    init(debounce: Duration = DisplayMonitor.defaultDebounce, clock: AppClock = SystemClock(),
         snapshotGate: SnapshotGate = SnapshotGate(),
         diagnostics: DiagnosticsRecording = DiagnosticsLog.shared) {
        self.diagnostics = diagnostics
        self.debounce = debounce
        self.snapshotGate = snapshotGate
        self.clock = clock
        (events, eventContinuation) = AsyncStream.makeStream(of: DisplayChangeEvent.self)
        (rawStream, rawContinuation) = AsyncStream.makeStream(of: RawDisplayEvent.self)
    }

    // MARK: Signals

    /// True from the first accepted callback until the debounce settles (debounce status only; the
    /// snapshot pause is `snapshotGate`, which stays closed past the settle).
    nonisolated var isChangeInProgress: Bool { gate.isChangeInProgress }
    nonisolated var suppressionDepth: Int { gate.suppressionDepth }

    // MARK: SelfChangeSuppressor

    nonisolated func beginSelfChange() { gate.beginSuppression() }
    nonisolated func endSelfChange() {
        gate.endSuppression()
        // Report how many callbacks the suppression swallowed (outside every lock).
        let swallowed = suppressedCount.withLock { count -> Int in
            defer { count = 0 }
            return count
        }
        if swallowed > 0 { diagnostics.record(.displaySuppressed(count: swallowed)) }
    }

    // MARK: Lifecycle

    /// Registers the CG callback and notification observer. Call on the main thread at startup.
    @MainActor
    func start() async {
        let registration = DisplayReconfigurationRegistration { [weak self] raw in
            self?.receive(raw) ?? false
        }
        await attach(registration)
        await startProcessing()
    }

    func stop() async {
        let current = registration
        registration = nil
        await current?.invalidate()
        settleTask?.cancel()
        processingTask?.cancel()
        processingTask = nil
        rawContinuation.finish()
        eventContinuation.finish()
        gate.setInProgress(false)
    }

    private func attach(_ newRegistration: DisplayReconfigurationRegistration) async {
        let old = registration
        registration = newRegistration
        await old?.invalidate()
    }

    /// Begins draining the raw stream. Separate from `start()` so tests can run without
    /// registering a real CG callback.
    func startProcessing() {
        guard processingTask == nil else { return }
        let stream = rawStream
        processingTask = Task { [weak self] in
            for await raw in stream {
                guard let self else { return }
                await self.ingest(raw)
            }
        }
    }

    // MARK: Ingest

    /// Synchronous entry point for every raw event. Applies suppression and the zero-vendor guard,
    /// then closes the snapshot gate BEFORE any debounce or async hop. Self-suppressed callbacks never
    /// touch the gate. Returns whether the event was accepted.
    @discardableResult
    nonisolated func receive(_ raw: RawDisplayEvent) -> Bool {
        if Self.isTransientZeroVendor(raw) { return false }
        guard gate.admit() else {
            suppressedCount.withLock { $0 += 1 }
            return false
        }
        var stamped = raw
        let wasOpen = snapshotGate.isOpen
        stamped.epoch = snapshotGate.closeForDisplayChange()
        // Recorded AFTER the gate call returned (never inside its lock). One event per open-to-closed
        // transition; further raw events are counted in the display-settled summary instead.
        if wasOpen { diagnostics.record(.gateClosed(epoch: stamped.epoch, raw: raw)) }
        rawContinuation.yield(stamped)
        return true
    }

    /// FM-3.2: displays mid-enumeration report vendor 0. Ignore them, except removals (the
    /// vendor lookup for a display that just went away is meaningless).
    nonisolated static func isTransientZeroVendor(_ raw: RawDisplayEvent) -> Bool {
        guard raw.source == .reconfigurationCallback, raw.vendorID == 0 else { return false }
        return !raw.summaryFlags.contains(.removeFlag)
    }

    /// Folds one accepted event into the pending burst and restarts the debounce window.
    func ingest(_ raw: RawDisplayEvent) {
        guard !Self.isTransientZeroVendor(raw) else { return }
        ingestedCount += 1
        gate.setInProgress(true)
        pending.rawEventCount += 1
        pending.throughEpoch = max(pending.throughEpoch, raw.epoch)
        if raw.source == .reconfigurationCallback {
            let flags = raw.summaryFlags
            if flags.contains(.addFlag) { pending.added.insert(raw.displayID) }
            if flags.contains(.removeFlag) { pending.removed.insert(raw.displayID) }
            if flags.contains(.movedFlag) { pending.moved.insert(raw.displayID) }
        }
        scheduleSettle()
    }

    private func scheduleSettle() {
        generation &+= 1
        let token = generation
        settleTask?.cancel()
        let clock = clock
        let window = debounce
        settleTask = Task { [weak self] in
            do { try await clock.sleep(for: window) } catch { return }
            await self?.settle(token: token)
        }
    }

    private func settle(token: Int) {
        guard token == generation else { return }  // a newer event restarted the window
        let event = pending
        pending = DisplayChangeEvent()
        settleTask = nil
        // The snapshot gate stays closed here; only AutomationController reopens it after ingesting
        // this event, so there is no open instant between settle and ingest.
        gate.setInProgress(false)
        diagnostics.record(.displaySettled(event))
        eventContinuation.yield(event)
    }
}

// MARK: - Diagnostics events

private extension DiagnosticsEvent {
    static func gateClosed(epoch: UInt64, raw: RawDisplayEvent) -> DiagnosticsEvent {
        DiagnosticsEvent(.gate, "gate-closed", fields: [
            "epoch": .int(Int(truncatingIfNeeded: epoch)),
            "source": .string(raw.source == .screenParameters ? "screen-parameters" : "reconfiguration-callback"),
            "flags": .int(Int(raw.flags))
        ])
    }

    static func displaySettled(_ event: DisplayChangeEvent) -> DiagnosticsEvent {
        func ids(_ set: Set<UInt32>) -> DiagnosticsValue { .string(set.sorted().map(String.init).joined(separator: ",")) }
        return DiagnosticsEvent(.display, "display-settled", fields: [
            "added": ids(event.added),
            "removed": ids(event.removed),
            "moved": ids(event.moved),
            "rawEventCount": .int(event.rawEventCount),
            "throughEpoch": .int(Int(truncatingIfNeeded: event.throughEpoch))
        ])
    }

    static func displaySuppressed(count: Int) -> DiagnosticsEvent {
        DiagnosticsEvent(.display, "display-suppressed", fields: ["count": .int(count)])
    }
}
