// SetupPresentationPolicy.swift
// Pure rules for when the setup window appears. No AppKit, no timers.

import Foundation

/// Why the setup window is (or would be) showing a permission request.
enum SetupReason: Equatable, Sendable {
    case firstRun
    case revoked
}

/// What the setup window should do at launch.
enum SetupLaunchDecision: Equatable, Sendable {
    /// Setup is done and Accessibility is trusted: stay hidden.
    case hidden
    /// Show the permission request.
    case showNeedsPermission(SetupReason)
    /// Setup never completed but the permission is already on: show the done state directly.
    case showGranted
}

enum SetupPresentationPolicy {
    /// Show at launch when setup is not completed or Accessibility is not trusted.
    static func launchDecision(setupCompleted: Bool, isTrusted: Bool) -> SetupLaunchDecision {
        switch (setupCompleted, isTrusted) {
        case (true, true): .hidden
        case (false, true): .showGranted
        case (false, false): .showNeedsPermission(.firstRun)
        case (true, false): .showNeedsPermission(.revoked)
        }
    }

    /// The reason a menu-warning click should present: the permission was never set up,
    /// or it was set up and has since been turned off.
    static func menuReason(setupCompleted: Bool) -> SetupReason {
        setupCompleted ? .revoked : .firstRun
    }

    /// The Settings pane label used in the copy. User-reported: "Device Control and Data Access"
    /// on macOS 27 or later. [UNVERIFIED - confirm in System Settings during UAT]
    static func paneName(for version: OperatingSystemVersion) -> String {
        version.majorVersion >= 27 ? "Device Control and Data Access" : "Accessibility"
    }
}

/// Shows the revoked window once per revocation: a grant arms it, the next loss of trust consumes it.
struct SetupRevocationTracker: Equatable, Sendable {
    private(set) var isArmed: Bool

    /// Armed only when the app starts trusted; an untrusted launch is already handled by the launch decision.
    init(startsTrusted: Bool) {
        isArmed = startsTrusted
    }

    /// Feed every trust change. Returns true when the revoked window should be shown.
    mutating func trustChanged(to trusted: Bool) -> Bool {
        if trusted {
            isArmed = true
            return false
        }
        guard isArmed else { return false }
        isArmed = false
        return true
    }
}
