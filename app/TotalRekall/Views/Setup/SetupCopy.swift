// SetupCopy.swift
// Pure copy for the first-run setup window. Visible text is fixed here so views and tests share it.

import SwiftUI

struct SetupCopy: Equatable, Sendable {
    enum Primary: Equatable, Sendable { case openSettings, relaunch, done }
    enum Secondary: Equatable, Sendable { case openSettings, notNow }

    let title: String
    let body: String
    let helper: String?
    let primary: Primary
    let primaryTitle: String
    let primaryHint: String
    let secondary: Secondary?
    let secondaryTitle: String?

    private static let askBody = "Total Rekall puts your windows back where they were each time you dock or undock "
        + "your Mac. To move windows for you, it needs Accessibility access."
    private static let firstRunTitle = "Let Total Rekall arrange your windows"
    private static let revokedTitle = "Total Rekall needs Accessibility again"
    private static let revokedBody = "Access was turned off in System Settings, so your windows won't move back "
        + "after you dock or undock. Turn it on again whenever you're ready."
    private static let waitingHelper = "Turn on Total Rekall in the Accessibility list.\nThis window updates by itself."

    init(state: SetupState, reason: SetupReason, paneName: String) {
        let openHint = "Opens System Settings > Privacy & Security > \(paneName)"
        let isRevoked = reason == .revoked
        let askTitle = isRevoked ? Self.revokedTitle : Self.firstRunTitle
        let askBody = isRevoked ? Self.revokedBody : Self.askBody
        switch state {
        case .needsPermission:
            title = askTitle
            body = askBody
            helper = nil
            primary = .openSettings
            primaryTitle = "Open System Settings"
            primaryHint = openHint
            secondary = isRevoked ? .notNow : nil
            secondaryTitle = isRevoked ? "Not Now" : nil
        case .waitingForGrant:
            title = askTitle
            body = askBody
            helper = Self.waitingHelper
            primary = .openSettings
            primaryTitle = "Open System Settings"
            primaryHint = openHint
            secondary = nil
            secondaryTitle = nil
        case .relaunchSuggested:
            title = "Already granted?\nRelaunch to finish enabling"
            body = "If Total Rekall is already turned on in Accessibility, macOS applies it the next time "
                + "the app opens."
            helper = nil
            primary = .relaunch
            primaryTitle = "Relaunch"
            primaryHint = "Quits and reopens Total Rekall so it sees the new permission"
            secondary = .openSettings
            secondaryTitle = "Open System Settings"
        case .granted:
            title = "You're all set"
            body = "Look for the bear in the menu bar. It keeps an eye on your desk and puts your windows "
                + "back whenever your displays change."
            helper = nil
            primary = .done
            primaryTitle = "Done"
            primaryHint = "Closes this window"
            secondary = nil
            secondaryTitle = nil
        }
    }
}
