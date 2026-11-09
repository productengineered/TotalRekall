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
    let paneName: String

    /// The controller shows (or fronts) the window.
    @ObservationIgnored var onPresent: (@MainActor () -> Void)?
    /// The controller closes the window.
    @ObservationIgnored var onClose: (@MainActor () -> Void)?

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
            if state == .granted { show(.needsPermission(.revoked), logged: .revoked) }
        } else if showRevoked {
            show(.needsPermission(.revoked), logged: .revoked)
        }
    }

    private func handleGrant() {
        guard isWindowVisible, state != .granted else {
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
        guard isWindowVisible, state != .granted else { return }
        status.openAccessibilitySettings()
        diagnostics.record(.setupOpenSettings())
        state = .waitingForGrant
        startTimeout()
    }

    /// "Relaunch Total Rekall".
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
    }
    #endif
}
