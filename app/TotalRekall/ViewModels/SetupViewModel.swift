// SetupViewModel.swift
// Logic behind the first-run setup window. Window-free: the controller
// supplies `onPresent` / `onClose`. Trust changes arrive by observing the monitor's @Observable
// `isTrusted` (`startObserving()`) or by the caller forwarding them to `trustDidChange(_:)`;
// AppDelegate's existing `onChange` consumer is never replaced.

import Foundation
import Observation

enum SetupState: Equatable, Sendable {
    case needsPermission(SetupReason)
    case waitingForGrant
    case relaunchSuggested
    case granted
    /// The last step: name this desk (docked) or explain it will be asked later (undocked).
    case namingDesk(SetupDeskKind)
}

enum SetupDeskKind: Equatable, Sendable { case docked, undocked }

/// The desk the setup step is naming, resolved from the live monitors when Continue is pressed.
struct SetupDeskInfo: Equatable, Sendable {
    let key: String
    /// The registered default name ("Desk N"); the same string the engine already holds.
    let name: String
    /// Names of every other desk, for the duplicate check.
    let otherNames: [String]
}

/// What the setup desk step needs from the engine. Main-actor so the view model stays simple.
@MainActor
protocol SetupDeskProviding: AnyObject {
    /// The desk for the connected external monitors (registered under its default name), or nil when only
    /// the built-in display is connected.
    func currentDesk() async -> SetupDeskInfo?
    /// Names the desk and saves its arrangement, only if the live monitors are still that desk.
    /// Returns false (and changes nothing) when they are not.
    func nameDesk(_ key: String, as name: String) async -> Bool
    /// The setup step is done with this desk; the new-desk prompt must never ask for it (D9).
    func markHandled(_ key: String)
}

/// Engine-backed provider. `liveLayout` reads the connected displays.
@MainActor
final class SetupDeskService: SetupDeskProviding {
    private let manager: DeskManaging
    private let liveLayout: @MainActor () -> MonitorLayout
    var onHandled: (@MainActor (String) -> Void)?

    init(manager: DeskManaging, liveLayout: @escaping @MainActor () -> MonitorLayout) {
        self.manager = manager
        self.liveLayout = liveLayout
    }

    func currentDesk() async -> SetupDeskInfo? {
        let live = liveLayout()
        guard DeskKey.hasExternalPanel(live), let key = DeskKey.make(for: live) else { return nil }
        // Register now so the prefilled default and the stored name are the same string.
        _ = await manager.registerNewDesk(live: live)
        let desks = await manager.deskSummaries()
        guard let current = desks.first(where: { $0.id == key }) else { return nil }
        return SetupDeskInfo(key: key, name: current.name, otherNames: desks.filter { $0.id != key }.map(\.name))
    }

    func nameDesk(_ key: String, as name: String) async -> Bool {
        let live = liveLayout()
        guard DeskKey.hasExternalPanel(live), DeskKey.make(for: live) == key else { return false }
        guard case .renamed = await manager.renameDesk(key, to: name) else { return false }
        if case .saved = await manager.saveDeskArrangement(key) { return true }
        return true   // named; the arrangement is learned by the next cycle if it was refused
    }

    func markHandled(_ key: String) { onHandled?(key) }
}

/// Persists "setup finished" across launches.
@MainActor
protocol SetupCompletionStoring: AnyObject {
    var isCompleted: Bool { get }
    func markCompleted()
}

@MainActor
final class UserDefaultsSetupCompletionStore: SetupCompletionStoring {
    static let key = "setupCompleted"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isCompleted: Bool { defaults.bool(forKey: Self.key) }
    func markCompleted() { defaults.set(true, forKey: Self.key) }
}

/// Why `setup-shown` was recorded.
enum SetupShownReason: String, Sendable {
    case firstLaunch = "first-launch"
    case firstLaunchTrusted = "first-launch-trusted"
    case revoked
    case menu
}

extension DiagnosticsEvent {
    static func setupShown(reason: SetupShownReason) -> DiagnosticsEvent {
        DiagnosticsEvent(.setup, "setup-shown", fields: ["reason": .code(reason)])
    }

    static func setupOpenSettings() -> DiagnosticsEvent {
        DiagnosticsEvent(.setup, "setup-open-settings")
    }

    static func setupGranted(seconds: Double) -> DiagnosticsEvent {
        DiagnosticsEvent(.setup, "setup-granted", fields: ["seconds": .double(seconds)])
    }

    static func setupRelaunchSuggested() -> DiagnosticsEvent {
        DiagnosticsEvent(.setup, "setup-relaunch-suggested")
    }

    static func setupRelaunch() -> DiagnosticsEvent {
        DiagnosticsEvent(.setup, "setup-relaunch")
    }

    static func setupSkipped() -> DiagnosticsEvent {
        DiagnosticsEvent(.setup, "setup-skipped")
    }
}

@MainActor
@Observable
final class SetupViewModel {
    /// How long to wait for a grant before suggesting a relaunch.
    static let relaunchTimeout: Duration = .seconds(10)

    private(set) var state: SetupState = .needsPermission(.firstRun)
    private(set) var reason: SetupReason = .firstRun
    private(set) var isWindowVisible = false
    /// Non-nil only while `state == .namingDesk(.docked)`.
    private(set) var deskModel: DeskNameModel?
    let paneName: String

    /// The controller shows (or fronts) the window.
    @ObservationIgnored var onPresent: (@MainActor () -> Void)?
    /// The controller closes the window.
    @ObservationIgnored var onClose: (@MainActor () -> Void)?

    /// Set by the app once the engine exists; nil behaves like an undocked Mac (no name field).
    @ObservationIgnored var deskProvider: SetupDeskProviding?
    @ObservationIgnored private var deskKey: String?
    @ObservationIgnored private(set) var deskSaveTask: Task<Void, Never>?

    @ObservationIgnored private let status: AccessibilityStatusProviding
    @ObservationIgnored private let store: SetupCompletionStoring
    @ObservationIgnored private let diagnostics: DiagnosticsRecording
    @ObservationIgnored private let clock: AppClock
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let relaunchAction: @MainActor () -> Void
    @ObservationIgnored private var revocation: SetupRevocationTracker
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var shownAt: Date?
    @ObservationIgnored private var observing = false

    init(
        status: AccessibilityStatusProviding,
        store: SetupCompletionStoring = UserDefaultsSetupCompletionStore(),
        diagnostics: DiagnosticsRecording = DiagnosticsLog.shared,
        clock: AppClock = SystemClock(),
        now: @escaping @MainActor () -> Date = { Date() },
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        relaunchAction: @escaping @MainActor () -> Void = { _ = AppRelauncher().relaunch() }
    ) {
        self.status = status
        self.store = store
        self.diagnostics = diagnostics
        self.clock = clock
        self.now = now
        self.relaunchAction = relaunchAction
        self.paneName = SetupPresentationPolicy.paneName(for: osVersion)
        self.revocation = SetupRevocationTracker(startsTrusted: status.isTrusted)
    }

    isolated deinit {
        timeoutTask?.cancel()
    }

    // MARK: Presentation

    /// Applies the launch policy. Returns true when the window should be shown.
    @discardableResult
    func evaluateLaunch() -> Bool {
        switch SetupPresentationPolicy.launchDecision(setupCompleted: store.isCompleted, isTrusted: status.isTrusted) {
        case .hidden:
            return false
        case .showNeedsPermission(let launchReason):
            show(.needsPermission(launchReason), logged: launchReason == .revoked ? .revoked : .firstLaunch)
        case .showGranted:
            store.markCompleted()
            show(.granted, logged: .firstLaunchTrusted)
        }
        return true
    }

    /// The menu warning was clicked: bring the window up, keeping its state if already open.
    func presentFromMenu() {
        if isWindowVisible {
            onPresent?()
            return
        }
        let menuReason = SetupPresentationPolicy.menuReason(setupCompleted: store.isCompleted)
        show(.needsPermission(menuReason), logged: .menu)
    }

    // MARK: Trust changes

    /// Begins following the monitor's `isTrusted` without taking over its `onChange` callback.
    func startObserving() {
        guard !observing else { return }
        observing = true
        observeTrust()
    }

    func stopObserving() {
        observing = false
    }

    private func observeTrust() {
        guard observing else { return }
        withObservationTracking {
            _ = status.isTrusted
        } onChange: { [weak self] in
            // onChange runs before the value is set; hop so the read sees the new value.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.trustDidChange(self.status.isTrusted)
                self.observeTrust()
            }
        }
    }

    /// Feed every trust change.
    func trustDidChange(_ trusted: Bool) {
        let showRevoked = revocation.trustChanged(to: trusted)
        if trusted {
            handleGrant()
            return
        }
        if isWindowVisible {
            // Revoked while the granted window is open. Any other open state is unchanged.
            if isPastPermission { show(.needsPermission(.revoked), logged: .revoked) }
        } else if showRevoked {
            show(.needsPermission(.revoked), logged: .revoked)
        }
    }

    private func handleGrant() {
        guard isWindowVisible, !isPastPermission else {
            // Hidden (or already done): just remember that setup is complete.
            if !isWindowVisible { store.markCompleted() }
            return
        }
        timeoutTask?.cancel()
        timeoutTask = nil
        store.markCompleted()
        let seconds = shownAt.map { max(0, now().timeIntervalSince($0)) } ?? 0
        state = .granted
        diagnostics.record(.setupGranted(seconds: seconds))
        // The window comes forward without taking focus (the controller decides how).
        onPresent?()
    }

    // MARK: User actions

    /// "Open System Settings" (and "Open System Settings Again").
    func openSystemSettings() {
        guard isWindowVisible, !isPastPermission else { return }
        status.openAccessibilitySettings()
        diagnostics.record(.setupOpenSettings())
        state = .waitingForGrant
        startTimeout()
    }

    /// "Relaunch TotalRekall".
    func relaunch() {
        diagnostics.record(.setupRelaunch())
        relaunchAction()
    }

    /// "Skip for now", Esc, close button, Cmd-W in any non-done state. Idempotent; never stores completion.
    func skip() {
        guard isWindowVisible else { return }
        if state == .granted {
            done()
            return
        }
        if case .namingDesk = state {
            leaveDeskStep()
            return
        }
        timeoutTask?.cancel()
        timeoutTask = nil
        diagnostics.record(.setupSkipped())
        isWindowVisible = false
        onClose?()
    }

    /// "Done" in the granted state. Idempotent.
    func done() {
        guard isWindowVisible else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        isWindowVisible = false
        onClose?()
    }

    // MARK: Desk step (named desks)

    /// "Continue" in the granted state: docked if an external monitor is connected, else undocked. The
    /// choice is made once, here; there is no live swap inside the step.
    func continueToDeskStep() async {
        guard isWindowVisible, state == .granted else { return }
        guard let info = await deskProvider?.currentDesk() else {
            guard isWindowVisible, state == .granted else { return }
            state = .namingDesk(.undocked)
            return
        }
        guard isWindowVisible, state == .granted else { return }
        deskKey = info.key
        deskModel = DeskNameModel(
            mode: .setup, initialName: info.name, otherNames: info.otherNames,
            onSave: { [weak self] name in self?.saveDesk(named: name) },
            onCancel: { [weak self] in self?.leaveDeskStep() }
        )
        state = .namingDesk(.docked)
    }

    /// "Done" in the undocked step.
    func finishUndockedStep() {
        leaveDeskStep()
    }

    /// Esc / close / Cmd-W (either desk state), and Done when undocked. The desk keeps its default name.
    func leaveDeskStep() {
        guard isWindowVisible, case .namingDesk = state else { return }
        handleDeskAndClose()
    }

    private func saveDesk(named name: String) {
        guard isWindowVisible, case .namingDesk(.docked) = state, let key = deskKey else { return }
        let provider = deskProvider
        deskSaveTask = Task { [weak self] in
            // If the monitors changed since Continue the provider changes nothing; the step just closes.
            _ = await provider?.nameDesk(key, as: name)
            self?.handleDeskAndClose()
        }
    }

    private func handleDeskAndClose() {
        guard isWindowVisible else { return }
        if let key = deskKey { deskProvider?.markHandled(key) }
        deskKey = nil
        deskModel = nil
        done()
    }

    private var isPastPermission: Bool {
        switch state {
        case .granted, .namingDesk: true
        default: false
        }
    }

    // MARK: Internals

    private func show(_ newState: SetupState, logged: SetupShownReason) {
        timeoutTask?.cancel()
        timeoutTask = nil
        if case .needsPermission(let newReason) = newState { reason = newReason }
        state = newState
        isWindowVisible = true
        shownAt = now()
        diagnostics.record(.setupShown(reason: logged))
        onPresent?()
    }

    private func startTimeout() {
        timeoutTask?.cancel()
        let clock = self.clock
        timeoutTask = Task { [weak self] in
            do {
                try await clock.sleep(for: SetupViewModel.relaunchTimeout)
            } catch {
                return
            }
            self?.timeoutElapsed()
        }
    }

    private func timeoutElapsed() {
        guard isWindowVisible, state == .waitingForGrant else { return }
        // A grant that arrived without a change callback still wins.
        status.refresh()
        if status.isTrusted {
            trustDidChange(true)
            return
        }
        state = .relaunchSuggested
        diagnostics.record(.setupRelaunchSuggested())
    }

    #if DEBUG
    /// Forces a state for previews and `-TRSetupPreviewState` (no timers, no real permission change).
    func forcePreviewState(_ newState: SetupState) {
        timeoutTask?.cancel()
        timeoutTask = nil
        if case .needsPermission(let newReason) = newState { reason = newReason }
        state = newState
        isWindowVisible = true
        if newState == .namingDesk(.docked) {
            deskModel = DeskNameModel(mode: .setup, initialName: "Desk 1", otherNames: [], onSave: { _ in }, onCancel: {})
        } else {
            deskModel = nil
        }
    }
    #endif
}
