import Foundation
import Observation

/// The plain-language state shown on the first menu line.
enum MenuStatus: Equatable {
    case accessibilityMissing, restoring, pausedDisplayChange, pausedDeskAbsent
    case pausedLayoutUnverified, pausedScreensAsleep, pausedWaitingForWindows
    case attention, autoRestoreOff
    case watching(lastSnapshot: Date?)
}

/// Drives every menu bar item's title, enabled state and the status icon.
/// Contains no AppKit; the menu controller renders these values.
@Observable
@MainActor
final class MenuBarViewModel {
    // MARK: Inputs
    var state: AppState = .idle
    var hasSnapshot = false
    var accessibilityGranted = true
    var hasFixableMonitors = true
    var lastResult: RestoreResult?
    var autoRestoreEnabled = true
    var snapshotIntervalMinutes = 10
    /// Why snapshots are paused right now (gate closed or docked set absent); nil when not paused.
    /// Set from the gate on menuWillOpen; no file I/O.
    var pauseReason: SnapshotRefusal?
    /// When the newest snapshot was written: set by the snapshot observer, or seeded at launch from disk.
    var lastSnapshotDate: Date?
    /// Why the last Save Snapshot Now was refused (or failed); nil after any successful save.
    var snapshotNotice: String?
    /// True while an Export Diagnostics run is in flight (the menu item is disabled and retitled).
    private(set) var isExporting = false
    /// Outcome of the last export, shown once under the item on the next menu open.
    private(set) var exportNotice: String?
    private var exportNoticeShown = false
    /// Cached "Last restore" submenu content (read from restore-log.json off the main thread).
    private(set) var lastRestoreDetail: LastRestoreDetail?
    /// restore-log.json exists but could not be decoded.
    private(set) var lastRestoreUnreadable = false
    /// Bumped per load request; only the newest request may publish (last writer wins).
    private var detailGeneration = 0
    /// Cached desk list for the Desks submenu (refreshed off menuWillOpen; no I/O when the menu opens).
    private(set) var desks: [DeskSummary] = []

    static let exportTitle = "Export Diagnostics…"
    static let exportingTitle = "Exporting Diagnostics…"
    static let exportDesktopNotice = "Diagnostics saved to the Desktop"
    static let exportFallbackNotice = "Couldn't use the Desktop. Saved in TotalRekall's folder."
    static let exportFailedNotice = "Export failed"

    // MARK: Dependencies
    private let snapshotActions: SnapshotActions
    private let restoreActions: RestoreActions
    private let logProvider: RestoreLogProviding
    private let exporter: DiagnosticsExporting
    private let revealer: FileRevealing?
    private let detailLoader: LastRestoreDetailLoading
    private let snapshotDateLoader: LastSnapshotDateLoading
    private let deskActions: DeskActions
    /// Called after a desk is forgotten, so the new-desk prompt can treat it as new again.
    var onDeskForgotten: (@MainActor (String) -> Void)?

    init(
        snapshotActions: SnapshotActions = StubSnapshotActions(),
        restoreActions: RestoreActions = StubRestoreActions(),
        logProvider: RestoreLogProviding = StubRestoreLogProvider(),
        exporter: DiagnosticsExporting = StubDiagnosticsExporter(),
        revealer: FileRevealing? = nil,
        detailLoader: LastRestoreDetailLoading = StubLastRestoreDetailLoader(),
        snapshotDateLoader: LastSnapshotDateLoading = StubLastSnapshotDateLoader(),
        deskActions: DeskActions = StubDeskActions()
    ) {
        self.deskActions = deskActions
        self.snapshotActions = snapshotActions
        self.restoreActions = restoreActions
        self.logProvider = logProvider
        self.exporter = exporter
        self.revealer = revealer
        self.detailLoader = detailLoader
        self.snapshotDateLoader = snapshotDateLoader
    }

    // MARK: Derived state
    private var isWorking: Bool { state == .working }

    var isSaveEnabled: Bool { accessibilityGranted && !isWorking }
    var isRestoreEnabled: Bool { hasSnapshot && accessibilityGranted && !isWorking }
    var isFixMonitorsEnabled: Bool { hasFixableMonitors && accessibilityGranted && !isWorking }
    /// Always available (a tester needs it most when something is broken), except while a run is in flight.
    var isExportEnabled: Bool { !isExporting }
    var exportTitle: String { isExporting ? Self.exportingTitle : Self.exportTitle }
    var isRevealLogEnabled: Bool { logProvider.hasLog }
    /// The permission line is the first item and the only enabled one above the separator.
    var showsAccessibilityWarning: Bool { !accessibilityGranted }
    /// Shown under the warning: a fresh process picks up a re-grant the running one may not see.
    static let relaunchForAccessibilityTitle = "Already granted? Relaunch to Finish Enabling"
    var isLastResultClickable: Bool { hasLastRestore }
    /// The in-memory result, else (after a relaunch) what the cached restore log says.
    var effectiveLastResult: RestoreResult? {
        if let lastResult { return lastResult }
        guard let detail = lastRestoreDetail else { return nil }
        if let restored = detail.restoredCount, let total = detail.totalCount {
            return .windows(restored: restored, total: total, date: detail.restoredAt)
        }
        if detail.monitorLine == RestoreDetailFormatter.monitorLine(from: "alreadyInOrder") {
            return .monitorsAlreadyInOrder(date: detail.restoredAt)
        }
        return .monitorsFixed(date: detail.restoredAt)
    }
    /// True when the "Last restore" line has a submenu to show.
    var hasLastRestore: Bool { effectiveLastResult != nil || lastRestoreUnreadable }

    /// SF Symbol name for the status item.
    var iconName: String {
        if !accessibilityGranted { return "exclamationmark.triangle" }
        switch state {
        case .idle, .working: return "arrow.counterclockwise.circle"
        case .attention: return "exclamationmark.circle"
        }
    }

    /// Working state animates the icon (static dot badge under Reduce Motion, handled by the view).
    var iconAnimates: Bool { accessibilityGranted && isWorking }

    /// What the app is doing, first match wins (menu-bar-spec §3).
    var status: MenuStatus {
        if !accessibilityGranted || pauseReason == .accessibilityMissing { return .accessibilityMissing }
        if isWorking || pauseReason == .restoring { return .restoring }
        switch pauseReason {
        case .displayChangeInProgress, .awaitingRestore: return .pausedDisplayChange
        case .dockedSetAbsent: return .pausedDeskAbsent
        case .layoutUnverified: return .pausedLayoutUnverified
        case .screensAsleep: return .pausedScreensAsleep
        case .sessionNotReady: return .pausedWaitingForWindows
        case .restoring, .accessibilityMissing, nil: break
        }
        if state == .attention { return .attention }
        if !autoRestoreEnabled { return .autoRestoreOff }
        return .watching(lastSnapshot: lastSnapshotDate)
    }

    /// Status line at the current time (refreshed each menuWillOpen; no timer).
    var statusLine: String { statusText(now: Date()) }

    // swiftlint:disable:next cyclomatic_complexity
    func statusText(now: Date, locale: Locale = .current) -> String {
        switch status {
        case .accessibilityMissing: return "Accessibility access needed"
        case .restoring: return "Restoring windows…"
        case .pausedDisplayChange: return "Paused — display change in progress"
        case .pausedDeskAbsent: return "Paused — \(deskLabel(fallback: "desk")) monitors not connected"
        case .pausedLayoutUnverified: return "Paused — monitor layout not verified"
        case .pausedScreensAsleep: return "Paused — screens are off"
        case .pausedWaitingForWindows: return "Paused — waiting for your windows after wake"
        case .attention: return "Needs attention — see Last restore"
        case .autoRestoreOff: return "Auto-restore is off"
        case .watching(let date?):
            return "Watching \(deskLabel(fallback: "your desk")) · last snapshot "
                + Self.relativeAge(of: date, now: now, locale: locale)
        case .watching(nil): return "Watching \(deskLabel(fallback: "your desk")) · no snapshot yet"
        }
    }

    /// The current desk's name where a desk is connected and named, else the plain wording. Never a key.
    private func deskLabel(fallback: String) -> String {
        guard let name = currentDesk?.name, !name.isEmpty else { return fallback }
        return name
    }

    /// "just now" under a minute, otherwise a short locale-aware relative phrase ("4 min. ago").
    nonisolated static func relativeAge(of date: Date, now: Date, locale: Locale = .current) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .numeric
        formatter.locale = locale
        return formatter.localizedString(for: date, relativeTo: now)
    }

    var accessibilityValue: String {
        if !accessibilityGranted { return "Accessibility access needed" }
        switch state {
        case .idle: return "Idle"
        case .working: return "Restoring windows"
        case .attention: return "Needs attention"
        }
    }

    /// "Last restore: X of Y windows, 2:35 PM"; yesterday reads "Yesterday at 8:27 PM", older shows the date too.
    func lastResultLine(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current,
                        timeFormatter: ((Date) -> String)? = nil) -> String {
        func stamp(_ date: Date) -> String {
            timeFormatter?(date) ?? RestoreDetailFormatter.timestamp(date, now: now, calendar: calendar, locale: locale)
        }
        switch effectiveLastResult {
        case .none:
            return lastRestoreUnreadable ? "Last restore" : "No restore yet"
        case .windows(let restored, let total, let date):
            return "Last restore: \(restored) of \(total) windows, \(stamp(date))"
        case .monitorsFixed(let date):
            return "Last restore: monitors fixed, \(stamp(date))"
        case .monitorsAlreadyInOrder(let date):
            return "Last restore: monitors already in order, \(stamp(date))"
        }
    }

    func triggerLine(_ detail: LastRestoreDetail, now: Date = Date(), calendar: Calendar = .current,
                     locale: Locale = .current) -> String {
        RestoreDetailFormatter.triggerLine(trigger: detail.trigger, date: detail.restoredAt, now: now,
                                           calendar: calendar, locale: locale)
    }

    // MARK: Last restore detail

    /// Reloads the cached detail from restore-log.json. Call at launch and after each restore outcome.
    /// A slower earlier load never overwrites the result of a newer request.
    func refreshLastRestoreDetail() async {
        detailGeneration += 1
        let generation = detailGeneration
        let result = await detailLoader.load()
        guard generation == detailGeneration else { return }
        switch result {
        case .none:
            lastRestoreDetail = nil
            lastRestoreUnreadable = false
        case .loaded(let detail):
            lastRestoreDetail = detail
            lastRestoreUnreadable = false
        case .unreadable:
            lastRestoreDetail = nil
            lastRestoreUnreadable = true
        }
    }

    /// Seeds `lastSnapshotDate` at launch from the newest saved snapshot (read off the main thread).
    /// Never replaces a newer date, so a seed arriving after a live snapshot is ignored.
    func seedLastSnapshotDate() async {
        guard let saved = await snapshotDateLoader.load() else { return }
        if let current = lastSnapshotDate, current >= saved { return }
        lastSnapshotDate = saved
    }

    /// A Fix Monitors result has no log of its own: show it directly and discard any load in flight.
    func setMonitorFixDetail(_ fix: FixOutcome, date: Date) {
        detailGeneration += 1
        lastRestoreDetail = RestoreDetailFormatter.detail(monitorFix: fix, date: date)
        lastRestoreUnreadable = false
    }

    // MARK: Desks (named desks)

    /// The desk whose monitors are connected now; nil with the built-in display alone.
    var currentDesk: DeskSummary? { desks.first(where: \.isCurrent) }
    /// Rename stays available while a restore runs; the other two need an idle, trusted app.
    var isRenameDeskEnabled: Bool { currentDesk != nil }
    var isSaveArrangementEnabled: Bool { currentDesk != nil && accessibilityGranted && !isWorking }
    var isForgetDeskEnabled: Bool { currentDesk != nil && !isWorking }

    /// Everything the Desks submenu shows, from cached state (no I/O when the menu opens).
    var desksMenuState: DesksMenuState {
        DesksMenuState(
            desks: desks.map { DesksMenuState.Entry(id: $0.id, name: $0.name, isCurrent: $0.isCurrent) },
            isTrusted: accessibilityGranted, isBusy: isWorking, notice: desksNotice)
    }

    /// One-shot line under Desks ("Saved this arrangement for Studio"); cleared when the menu closes.
    private(set) var desksNotice: String?
    private var desksNoticeShown = false

    func markDesksNoticeShown() { desksNoticeShown = true }

    /// Save Current Arrangement for the desk that is current when the item is clicked.
    func saveCurrentArrangement() async {
        guard isSaveArrangementEnabled, let desk = currentDesk else { return }
        switch await saveDeskArrangement(desk.id) {
        case .saved: desksNotice = "Saved this arrangement for \(desk.name)"
        case .refused(let message), .failed(let message): desksNotice = message
        case .notCurrentDesk: desksNotice = "These monitors are no longer connected"
        }
        desksNoticeShown = false
    }

    func refreshDesks() async {
        desks = await deskActions.deskSummaries()
    }

    /// Live names of every desk except `key`, for a name field's duplicate check.
    func deskNames(excluding key: String) -> [String] {
        desks.filter { $0.id != key }.map(\.name)
    }

    func renameDesk(_ key: String, to name: String) async -> DeskRenameResult {
        let result = await deskActions.renameDesk(key, to: name)
        await refreshDesks()
        return result
    }

    /// Re-learn plus snapshot now for the desk captured by the caller. Refused while untrusted or busy.
    func saveDeskArrangement(_ key: String) async -> DeskArrangementResult {
        guard accessibilityGranted else { return .refused(SnapshotRefusal.accessibilityMissing.message) }
        guard !isWorking else { return .refused(SnapshotRefusal.restoring.message) }
        return await deskActions.saveDeskArrangement(key)
    }

    /// Save this desk? / setup step: name the desk, then save its arrangement. The arrangement is
    /// saved only if the connected monitors are still that desk (the engine checks); a rename the
    /// rules refuse returns that problem and saves nothing.
    func nameDesk(_ key: String, as name: String) async -> DeskArrangementResult? {
        guard case .renamed = await renameDesk(key, to: name) else { return nil }
        return await saveDeskArrangement(key)
    }

    func forgetDesk(_ key: String) async -> Bool {
        guard !isWorking else { return false }
        let forgotten = await deskActions.forgetDesk(key)
        if forgotten { onDeskForgotten?(key) }
        await refreshDesks()
        return forgotten
    }

    // MARK: Actions
    func saveNow() async {
        guard isSaveEnabled else { return }
        await snapshotActions.saveNow()
    }

    func restoreNow() async {
        guard isRestoreEnabled else { return }
        await restoreActions.restoreNow()
    }

    func fixMonitors() async {
        guard isFixMonitorsEnabled else { return }
        await restoreActions.fixMonitors()
    }

    func exportDiagnostics() async {
        guard !isExporting else { return }
        isExporting = true
        exportNotice = nil
        exportNoticeShown = false
        defer { isExporting = false }
        let result = await exporter.export()
        switch result {
        case .desktop(let url):
            exportNotice = Self.exportDesktopNotice
            revealer?.reveal(url)
        case .fallback(let url):
            exportNotice = Self.exportFallbackNotice
            revealer?.reveal(url)
        case .failed:
            exportNotice = Self.exportFailedNotice
        }
    }

    /// The menu displayed the export notice in this open; it clears when the menu closes.
    func markExportNoticeShown() { exportNoticeShown = true }

    func clearShownNotices() {
        if desksNoticeShown {
            desksNotice = nil
            desksNoticeShown = false
        }
        if exportNoticeShown {
            exportNotice = nil
            exportNoticeShown = false
        }
    }

    /// URL to reveal in Finder, or nil when there is no log.
    func restoreLogURLToReveal() -> URL? {
        isRevealLogEnabled ? logProvider.logURL : nil
    }
}
