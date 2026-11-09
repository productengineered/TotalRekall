import AppKit
import ApplicationServices
import Observation

/// Abstraction over the trust check so tests never touch the real TCC database.
protocol AccessibilityTrustChecking: Sendable {
    func isProcessTrusted() -> Bool
}

/// Real check backed by `AXIsProcessTrustedWithOptions` with the prompt disabled.
/// The OS may keep a stale per-process value after a TCC change; the menu offers a relaunch for that.
struct SystemAccessibilityTrustChecker: AccessibilityTrustChecking {
    func isProcessTrusted() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

/// What the menu bar view model consumes.
@MainActor
protocol AccessibilityStatusProviding: AnyObject {
    var isTrusted: Bool { get }
    /// Called on the main actor whenever trust flips (grant or mid-session revocation).
    var onChange: (@MainActor (Bool) -> Void)? { get set }
    func refresh()
    func openAccessibilitySettings()
}

/// Detects Accessibility permission, including revocation mid-session, by re-checking on
/// app activation, on menu open, and on an adaptive timer. An accessory app rarely becomes active,
/// so the timer is the primary source: fast while untrusted (catch the re-grant), a bit slower while trusted.
@MainActor
@Observable
final class AccessibilityMonitor: AccessibilityStatusProviding {
    /// Deep link to System Settings > Privacy & Security > Accessibility.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")

    private(set) var isTrusted: Bool
    @ObservationIgnored var onChange: (@MainActor (Bool) -> Void)?

    @ObservationIgnored private let checker: AccessibilityTrustChecking
    @ObservationIgnored let trustedPollInterval: Duration
    @ObservationIgnored let untrustedPollInterval: Duration
    @ObservationIgnored private let urlOpener: @MainActor (URL) -> Void
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    static let defaultTrustedPollInterval: Duration = .seconds(3)
    static let defaultUntrustedPollInterval: Duration = .seconds(2)

    init(
        checker: AccessibilityTrustChecking = SystemAccessibilityTrustChecker(),
        trustedPollInterval: Duration = AccessibilityMonitor.defaultTrustedPollInterval,
        untrustedPollInterval: Duration = AccessibilityMonitor.defaultUntrustedPollInterval,
        notificationCenter: NotificationCenter = .default,
        urlOpener: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.checker = checker
        self.trustedPollInterval = trustedPollInterval
        self.untrustedPollInterval = untrustedPollInterval
        self.notificationCenter = notificationCenter
        self.urlOpener = urlOpener
        self.isTrusted = checker.isProcessTrusted()
    }

    /// Same interval in both states (kept for callers that want a fixed cadence).
    convenience init(
        checker: AccessibilityTrustChecking,
        pollInterval: Duration,
        notificationCenter: NotificationCenter = .default,
        urlOpener: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.init(
            checker: checker, trustedPollInterval: pollInterval, untrustedPollInterval: pollInterval,
            notificationCenter: notificationCenter, urlOpener: urlOpener
        )
    }

    /// The wait before the next poll, chosen from the current state.
    var currentPollInterval: Duration { isTrusted ? trustedPollInterval : untrustedPollInterval }

    isolated deinit {
        pollTask?.cancel()
        if let activationObserver { notificationCenter.removeObserver(activationObserver) }
    }

    /// Begins observing app activation and polling. Idempotent.
    func start() {
        guard pollTask == nil else { return }
        activationObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.currentPollInterval else { break }
                try? await Task.sleep(for: interval)
                if Task.isCancelled { break }
                self?.refresh()
            }
        }
        refresh()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        if let activationObserver { notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    /// Re-reads trust and notifies only on a change.
    func refresh() {
        let current = checker.isProcessTrusted()
        guard current != isTrusted else { return }
        isTrusted = current
        onChange?(current)
    }

    func openAccessibilitySettings() {
        guard let url = Self.settingsURL else { return }
        urlOpener(url)
    }
}
