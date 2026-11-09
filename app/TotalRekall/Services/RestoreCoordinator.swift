// RestoreCoordinator.swift
// Single entry point for every restore trigger. Sequence (TECHNICAL_SPEC v1.1):
//   Accessibility guard -> single-flight -> detect swap -> fix monitors (self-change suppressed)
//   -> re-resolve desktops -> RestorePlan from the latest snapshot -> WindowRestorer -> RestoreLog
//   -> summary. The coordinator returns a RestoreOutcome; the menu adapter publishes it.
// Every system dependency sits behind a small protocol so the ordering is testable with fakes.

import Foundation
import os

// MARK: - Outcome

enum RestoreOutcome: Equatable, Sendable {
    /// Accessibility is not granted; nothing was touched.
    case refusedNoAccessibility
    /// Another restore or monitor fix is already running; this request was dropped.
    case droppedInFlight
    /// No snapshot exists for the connected displays.
    case noSnapshot
    /// The pipeline ran. `summary.needsAttention` drives the attention icon.
    case restored(RestoreSummary)
    /// A wake restore that provably did nothing (`QuietWakePolicy`): recorded in the diagnostics trail
    /// only. Last restore, restore-log.json and notifications are left alone.
    case quietWake(RestoreSummary)
    /// Fix Monitors finished. `fix` is the MonitorFixer outcome.
    case monitorsFixed(FixOutcome, date: Date)
    /// The pipeline could not run (Spaces topology unreadable, snapshot unreadable).
    case failed(String)
}

// MARK: - Seams

protocol SnapshotLoading: Sendable {
    func load() async throws -> SnapshotFile
}

extension SnapshotStore: SnapshotLoading {}

protocol MonitorFixing: Sendable {
    func fix(learned: MonitorLayout) -> FixOutcome
}

extension MonitorFixer: MonitorFixing {}

protocol SpaceTopologyProviding: Sendable {
    func topology() async throws -> [DisplaySpaces]
}

protocol LiveWindowProviding: Sendable {
    /// Live state for the given CGWindowIDs. Windows that no longer exist are omitted.
    func liveWindows(ids: Set<UInt32>) async -> [LiveWindowState]
}

protocol RestoreLogWriting: Sendable {
    func write(_ log: RestoreLog) throws
}

extension RestoreLogStore: RestoreLogWriting {}

// MARK: - Coordinator

actor RestoreCoordinator {
    private static let logger = Logger(subsystem: "com.productengineered.TotalRekall", category: "restore")

    private let trust: AccessibilityTrustChecking
    private let displays: DisplayProviding
    private let snapshots: SnapshotLoading
    private let learnedLayout: @Sendable () async -> MonitorLayout
    private let fixer: MonitorFixing
    private let topology: SpaceTopologyProviding
    private let liveWindows: LiveWindowProviding
    private let restorer: WindowRestoring
    private let logWriter: RestoreLogWriting
    private let capability: SpaceBridgeCapability
    private let now: @Sendable () -> Date
    private let diagnostics: any DiagnosticsRecording
    /// Total Rekall's own bundle: snapshots written before own windows were excluded still hold one,
    /// and it is never a user window to restore.
    private let ownBundleID: String?

    private(set) var restoreInFlight = false

    init(
        trust: AccessibilityTrustChecking,
        displays: DisplayProviding,
        snapshots: SnapshotLoading,
        learnedLayout: @escaping @Sendable () async -> MonitorLayout = { MonitorLayout(origins: [:]) },
        fixer: MonitorFixing,
        topology: SpaceTopologyProviding,
        liveWindows: LiveWindowProviding,
        restorer: WindowRestoring,
        logWriter: RestoreLogWriting,
        capability: SpaceBridgeCapability,
        now: @escaping @Sendable () -> Date = { Date() },
        diagnostics: any DiagnosticsRecording = DiagnosticsLog.shared,
        ownBundleID: String? = Bundle.main.bundleIdentifier
    ) {
        self.ownBundleID = ownBundleID
        self.trust = trust
        self.displays = displays
        self.snapshots = snapshots
        self.learnedLayout = learnedLayout
        self.fixer = fixer
        self.topology = topology
        self.liveWindows = liveWindows
        self.restorer = restorer
        self.logWriter = logWriter
        self.capability = capability
        self.now = now
        self.diagnostics = diagnostics
    }

    // MARK: Restore Now

    func restoreNow(context cycle: CycleContext) async -> RestoreOutcome {
        guard trust.isProcessTrusted() else { return .refusedNoAccessibility }
        // No suspension point between the check and the set: the actor makes this atomic.
        guard !restoreInFlight else { return .droppedInFlight }
        restoreInFlight = true
        defer { restoreInFlight = false }

        let context: SnapshotContext
        switch await loadContext() {
        case .success(let c): context = c
        case .failure(let outcome): return outcome
        }

        diagnostics.record(.restoreStarted(cycleID: cycle.cycleID, trigger: cycle.trigger, capability: capability))

        // Steps 1-2: detect the swap by serial and fix it, suppressing our own reconfiguration.
        let fixOutcome = detectAndFix(context: context, cycleID: cycle.cycleID)
        Self.logger.info("monitor fix: \(String(describing: fixOutcome))")

        // Step 3: re-resolve desktops on the (possibly changed) live topology.
        let spaces: [DisplaySpaces]
        do {
            spaces = try await topology.topology()
        } catch {
            diagnostics.record(.restoreFailed(cycleID: cycle.cycleID, reason: "spaces-unavailable"))
            return .failed("Spaces unavailable: \(error)")
        }

        // Step 4: plan from the latest good snapshot against live windows.
        let saved = context.config.windows.filter { $0.bundleID != ownBundleID }
        let wanted = Set(saved.compactMap(\.windowID))
        let live = await liveWindows.liveWindows(ids: wanted)
        let plan = RestorePlan.build(snapshot: saved, live: live,
                                     topology: spaces, capability: capability)
        diagnostics.record(.restorePlan(cycleID: cycle.cycleID, plan: plan))

        // Step 5: execute.
        let results = await restorer.execute(plan)
        let snapshotByID = Dictionary(context.config.windows.map { ($0.id, $0) }) { first, _ in first }
        for result in results {
            diagnostics.record(.windowResult(cycleID: cycle.cycleID, result: result,
                                             desktop: snapshotByID[result.snapshotID]?.desktopKey))
        }

        // Step 6: log, then summarize. A log write failure never hides the result. A quiet wake
        // keeps the previous log: it is recorded in the diagnostics trail only.
        let date = now()
        if isQuietWake(cycle: cycle, fix: fixOutcome, config: context.config, results: results) {
            let summary = RestoreSummary(results: results, date: date, monitorFix: fixOutcome)
            diagnostics.record(.restoreFinished(cycleID: cycle.cycleID, summary: summary, quiet: true))
            return .quietWake(summary)
        }
        let log = RestoreLog(results: results, date: date, configKey: context.config.fingerprint,
                             capability: capability, layout: context.layout, monitorFix: fixOutcome,
                             context: cycle)
        do {
            try logWriter.write(log)
        } catch {
            Self.logger.error("restore log write failed: \(String(describing: error))")
            diagnostics.record(.restoreLogWriteFailed(cycleID: cycle.cycleID))
        }
        let summary = RestoreSummary(results: results, date: date, monitorFix: fixOutcome)
        diagnostics.record(.restoreFinished(cycleID: cycle.cycleID, summary: summary))
        return .restored(summary)
    }

    private func isQuietWake(cycle: CycleContext, fix: FixOutcome, config: DisplayConfigSnapshot,
                             results: [RestoreWindowResult]) -> Bool {
        QuietWakePolicy.isQuiet(QuietWakePolicy.Input(
            trigger: cycle.trigger, eligibility: cycle.quietWake, fix: fix,
            snapshotWindows: config.windows.map { .init(id: $0.id, bundleID: $0.bundleID) },
            ownBundleID: ownBundleID, results: results))
    }

    // MARK: Fix Monitors

    /// Steps 1-2 only: detect and fix against the last learned layout.
    func fixMonitors(context cycle: CycleContext) async -> RestoreOutcome {
        guard trust.isProcessTrusted() else { return .refusedNoAccessibility }
        guard !restoreInFlight else { return .droppedInFlight }
        restoreInFlight = true
        defer { restoreInFlight = false }

        switch await loadContext() {
        case .failure(let outcome):
            return outcome
        case .success(let context):
            let outcome = detectAndFix(context: context, cycleID: cycle.cycleID)
            return .monitorsFixed(outcome, date: now())
        }
    }

    // MARK: Monitor fix

    /// Records what the swap check saw (panel serials in learned vs live order), runs the fixer, and
    /// records its outcome. The check here mirrors the fixer's own detection and has no side effects.
    private func detectAndFix(context: SnapshotContext, cycleID: UUID) -> FixOutcome {
        let live = displays.currentDisplays()
        let verdict = SwapDetector.detect(
            learned: context.layout, live: MonitorLayout.from(displays: live),
            hasUnreadableSerial: live.contains { $0.serialString == nil }
        )
        diagnostics.record(.swapCheck(cycleID: cycleID, verdict: verdict, learned: context.layout,
                                      live: MonitorLayout.from(displays: live)))
        let outcome = fixer.fix(learned: context.layout)
        diagnostics.record(.monitorFix(cycleID: cycleID, outcome: outcome))
        return outcome
    }

    // MARK: Queries

    /// True when a snapshot with windows exists for the connected displays.
    func hasSnapshot() async -> Bool {
        if case .success = await loadContext() { return true }
        return false
    }

    // MARK: Snapshot context

    private struct SnapshotContext {
        let config: DisplayConfigSnapshot
        /// Layout to detect the swap against: LearnedLayoutStore (learned before the pause), falling
        /// back to the origins in the latest snapshot for this display set when nothing is learned yet
        /// (e.g. right after relaunch).
        let layout: MonitorLayout
    }

    private enum ContextResult {
        case success(SnapshotContext)
        case failure(RestoreOutcome)
    }

    private func loadContext() async -> ContextResult {
        let serials = displays.currentDisplays().compactMap(\.serialString)
        guard !serials.isEmpty else { return .failure(.noSnapshot) }
        let key = SnapshotKey.make(panelSerials: serials)
        let file: SnapshotFile
        do {
            file = try await snapshots.load()
        } catch {
            return .failure(.failed("Snapshot unreadable: \(error)"))
        }
        guard let config = file.configurations[key], !config.windows.isEmpty else { return .failure(.noSnapshot) }
        var origins: [String: MonitorLayout.Origin] = [:]
        for d in config.displays {
            if let serial = d.panelSerial { origins[serial] = MonitorLayout.Origin(x: d.originX, y: d.originY) }
        }
        let learned = await learnedLayout()
        let layout = learned.origins.isEmpty ? MonitorLayout(origins: origins) : learned
        return .success(SnapshotContext(config: config, layout: layout))
    }
}

// MARK: - Live providers

/// Space topology for the connected displays, resolving SLS display identifiers to panel serials.
struct LiveSpaceTopologyProvider: SpaceTopologyProviding {
    let bridge: SpaceBridge
    let displayProvider: DisplayProviding

    func topology() async throws -> [DisplaySpaces] {
        let displays = displayProvider.currentDisplays()
        let online = displays.map(\.displayID)
        let serialByDisplayID = Dictionary(displays.map { ($0.displayID, $0.serial) }) { first, _ in first }
        return try await bridge.displaySpaces { identifier in
            SLSDisplayIdentifier.displayID(for: identifier, online: online).flatMap { serialByDisplayID[$0] }
        }
    }
}

/// Joins CG frames, AX reachability and SLS Space ids for the requested windows.
struct LiveWindowStateProvider: LiveWindowProviding {
    let bridge: SpaceBridge
    let windowList: WindowListProviding
    let axProbe: AXWindowProbing

    func liveWindows(ids: Set<UInt32>) async -> [LiveWindowState] {
        let found = windowList.windowList().filter { ids.contains($0.windowID) }
        var axVisible = Set<UInt32>()
        for pid in Set(found.map(\.ownerPID)) {
            axVisible.formUnion(axProbe.states(pid: pid).keys)
        }
        var result: [LiveWindowState] = []
        for w in found {
            let spaces = (try? await bridge.spaceIDs(forWindows: [w.windowID])) ?? []
            result.append(LiveWindowState(windowID: w.windowID, frame: w.frame,
                                          axVisible: axVisible.contains(w.windowID), spaceIDs: spaces))
        }
        return result
    }
}

// MARK: - Diagnostics events

/// Bounded vocabulary for `RestoreWindowResult.detail` so free text never reaches the diary.
enum RestoreDetailKind: String, Sendable {
    case none
    case frameWritten = "frame-written"
    case axUnreachable = "ax-unreachable"
    case axUnreachableLeftInPlace = "ax-unreachable-left-in-place"
    case returnedToDesktop = "returned-to-desktop"
    case returnUnconfirmed = "return-unconfirmed"
    case bringToCurrentUnconfirmed = "bring-to-current-unconfirmed"
    case currentSpaceUnknown = "current-space-unknown"
    case spaceMoveUnconfirmed = "space-move-unconfirmed"
    case other

    init(detail: String?) {
        guard let detail, !detail.isEmpty else { self = .none; return }
        if detail.contains("return to original desktop unconfirmed") { self = .returnUnconfirmed }
        else if detail.contains("returned to original desktop") { self = .returnedToDesktop }
        else if detail.contains("left on its desktop") { self = .axUnreachableLeftInPlace }
        else if detail.hasPrefix("AX cannot see window") { self = .axUnreachable }
        else if detail == "bring-to-current unconfirmed" { self = .bringToCurrentUnconfirmed }
        else if detail == "current Space unknown" { self = .currentSpaceUnknown }
        else if detail == "final Space move unconfirmed" { self = .spaceMoveUnconfirmed }
        else if detail.contains("attempts") { self = .frameWritten }
        else { self = .other }
    }
}

extension DiagnosticsEvent {
    private static func capabilityFields(_ capability: SpaceBridgeCapability) -> [String: DiagnosticsValue] {
        switch capability {
        case .full: ["capability": .string("full")]
        case .positionOnly(let reason): ["capability": .string("position-only"), "reason": .string(reason)]
        }
    }

    /// Panel serials ordered by origin (x, then y), comma-joined.
    private static func panelOrder(_ layout: MonitorLayout) -> String {
        layout.origins.sorted { ($0.value.x, $0.value.y, $0.key) < ($1.value.x, $1.value.y, $1.key) }
            .map(\.key).joined(separator: ",")
    }

    static func restoreStarted(cycleID: UUID, trigger: CycleTrigger,
                               capability: SpaceBridgeCapability) -> DiagnosticsEvent {
        var fields = capabilityFields(capability)
        fields["trigger"] = .code(trigger)
        return DiagnosticsEvent(.restore, "restore-started", cycleID: cycleID, fields: fields)
    }

    static func swapCheck(cycleID: UUID, verdict: SwapVerdict, learned: MonitorLayout,
                          live: MonitorLayout) -> DiagnosticsEvent {
        var fields: [String: DiagnosticsValue] = [
            "learned_order": .string(panelOrder(learned)), "live_order": .string(panelOrder(live))
        ]
        switch verdict {
        case .correct: fields["verdict"] = .string("correct")
        case .swapped: fields["verdict"] = .string("swapped")
        case .unknown(let reason):
            fields["verdict"] = .string("unknown")
            fields["reason"] = .string(reason)
        }
        return DiagnosticsEvent(.monitors, "swap-check", cycleID: cycleID, fields: fields)
    }

    static func monitorFix(cycleID: UUID, outcome: FixOutcome) -> DiagnosticsEvent {
        var fields: [String: DiagnosticsValue] = [:]
        switch outcome {
        case .verified: fields["kind"] = .string("verified")
        case .alreadyInOrder: fields["kind"] = .string("already-in-order")
        case .unverified(let reason): fields["kind"] = .string("unverified"); fields["reason"] = .string(reason)
        case .skipped(let reason): fields["kind"] = .string("skipped"); fields["reason"] = .string(reason)
        case .failed(let reason): fields["kind"] = .string("failed"); fields["reason"] = .string(reason)
        }
        return DiagnosticsEvent(.monitors, "monitor-fix", cycleID: cycleID, fields: fields)
    }

    static func restorePlan(cycleID: UUID, plan: RestorePlan) -> DiagnosticsEvent {
        var counts = (already: 0, frame: 0, move: 0, bring: 0, skip: 0)
        for window in plan.windows {
            switch window.action {
            case .alreadyCorrect: counts.already += 1
            case .frameFix: counts.frame += 1
            case .moveSpace: counts.move += 1
            case .bringToCurrent: counts.bring += 1
            case .skip: counts.skip += 1
            }
        }
        return DiagnosticsEvent(.restore, "restore-plan", cycleID: cycleID, fields: [
            "windows": .int(plan.windows.count), "already_correct": .int(counts.already),
            "frame_fix": .int(counts.frame), "move_space": .int(counts.move),
            "bring_to_current": .int(counts.bring), "skip": .int(counts.skip)
        ])
    }

    /// Maps fields explicitly: the result's `title` is never read.
    static func windowResult(cycleID: UUID, result: RestoreWindowResult, desktop: DesktopKey?) -> DiagnosticsEvent {
        var fields: [String: DiagnosticsValue] = [
            "bundle_id": .string(result.bundleID), "app_name": .string(result.appName),
            "window_id": .int(result.windowID.map(Int.init) ?? -1),
            "status": .string(result.status.logValue),
            "detail": .string(RestoreDetailKind(detail: result.detail).rawValue)
        ]
        if let desktop {
            fields["desktop_panel"] = .string(desktop.panelSerial)
            fields["desktop_ordinal"] = .int(desktop.ordinal)
        }
        return DiagnosticsEvent(.restore, "window-result", cycleID: cycleID, fields: fields)
    }

    /// `quiet` adds `quiet: true` (a quiet wake that skipped the restore-log write); absent otherwise.
    static func restoreFinished(cycleID: UUID, summary: RestoreSummary, quiet: Bool = false) -> DiagnosticsEvent {
        var fields: [String: DiagnosticsValue] = [
            "total": .int(summary.total), "restored": .int(summary.restored),
            "unverified": .int(summary.unverified), "unreachable": .int(summary.unreachable),
            "failed": .int(summary.failed), "desktop_missing": .int(summary.desktopMissing),
            "intentionally_skipped": .int(summary.intentionallySkipped),
            "left_in_place": .int(summary.leftInPlace), "needs_attention": .bool(summary.needsAttention)
        ]
        if quiet { fields["quiet"] = .bool(true) }
        return DiagnosticsEvent(.restore, "restore-finished", cycleID: cycleID, fields: fields)
    }

    static func restoreFailed(cycleID: UUID, reason: String) -> DiagnosticsEvent {
        DiagnosticsEvent(.restore, "restore-failed", cycleID: cycleID, fields: ["reason": .string(reason)])
    }

    static func restoreLogWriteFailed(cycleID: UUID) -> DiagnosticsEvent {
        DiagnosticsEvent(.restore, "restore-log-write-failed", cycleID: cycleID)
    }

    static func spaceBridgeProbe(capability: SpaceBridgeCapability) -> DiagnosticsEvent {
        DiagnosticsEvent(.spacebridge, "spacebridge-probe", fields: capabilityFields(capability))
    }

    static func appLaunchedDetail(version: String, build: String, osVersion: String,
                                  accessibilityTrusted: Bool, capability: SpaceBridgeCapability) -> DiagnosticsEvent {
        var fields = capabilityFields(capability)
        fields["version"] = .string(version)
        fields["build"] = .string(build)
        fields["os_version"] = .string(osVersion)
        fields["accessibility_trusted"] = .bool(accessibilityTrusted)
        return DiagnosticsEvent(.lifecycle, "app-launched", fields: fields)
    }

    static func accessibilityChanged(trusted: Bool) -> DiagnosticsEvent {
        DiagnosticsEvent(.permissions, "accessibility-changed", fields: ["trusted": .bool(trusted)])
    }
}
