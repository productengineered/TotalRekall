// SetupCopy.swift
// Pure copy for the first-run setup window. Visible text is fixed here so views and tests share it.

import SwiftUI

struct SetupCopy: Equatable, Sendable {
    enum Primary: Equatable, Sendable { case openSettings, relaunch, done, continueSetup, saveDesk }
    enum Secondary: Equatable, Sendable { case openSettings, notNow }

    let title: String
    let body: String
    let helper: String?
    let primary: Primary
    let primaryTitle: String
    let primaryHint: String
    let secondary: Secondary?
    let secondaryTitle: String?
    /// True only in the docked desk step.
    let showsDeskField: Bool

    private static let askBody = "TotalRekall puts your windows back where they were each time you dock or undock "
        + "your Mac. To move windows for you, it needs Accessibility access."
    private static let firstRunTitle = "Let TotalRekall arrange your windows"
    private static let revokedTitle = "TotalRekall needs Accessibility again"
    private static let revokedBody = "Access was turned off in System Settings, so your windows won't move back "
        + "after you dock or undock. Turn it on again whenever you're ready."
    private static let waitingHelper = "Turn on TotalRekall in the Accessibility list.\nThis window updates by itself."

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
            showsDeskField = false
        case .waitingForGrant:
            title = askTitle
            body = askBody
            helper = Self.waitingHelper
            primary = .openSettings
            primaryTitle = "Open System Settings"
            primaryHint = openHint
            secondary = nil
            secondaryTitle = nil
            showsDeskField = false
        case .relaunchSuggested:
            title = "Already granted?\nRelaunch to finish enabling"
            body = "If TotalRekall is already turned on in Accessibility, macOS applies it the next time "
                + "the app opens."
            helper = nil
            primary = .relaunch
            primaryTitle = "Relaunch"
            primaryHint = "Quits and reopens TotalRekall so it sees the new permission"
            secondary = .openSettings
            secondaryTitle = "Open System Settings"
            showsDeskField = false
        case .granted:
            title = "You're all set"
            body = "Look for the bear in the menu bar. It keeps an eye on your desk and puts your windows "
                + "back whenever your displays change."
            helper = nil
            primary = .continueSetup
            primaryTitle = SetupDeskCopy.continueTitle
            primaryHint = SetupDeskCopy.continueHint
            secondary = nil
            secondaryTitle = nil
            showsDeskField = false
        case .namingDesk(.docked):
            title = SetupDeskCopy.dockedTitle
            body = SetupDeskCopy.dockedBody
            helper = nil
            primary = .saveDesk
            primaryTitle = SetupDeskCopy.saveTitle
            primaryHint = SetupDeskCopy.saveHint
            secondary = nil
            secondaryTitle = nil
            showsDeskField = true
        case .namingDesk(.undocked):
            title = SetupDeskCopy.undockedTitle
            body = SetupDeskCopy.undockedBody
            helper = nil
            primary = .done
            primaryTitle = SetupDeskCopy.undockedDoneTitle
            primaryHint = SetupDeskCopy.undockedDoneHint
            secondary = nil
            secondaryTitle = nil
            showsDeskField = false
        }
    }
}

/// Copy for the setup desk step (named desks).
enum SetupDeskCopy {
    static let dockedTitle = "Name this desk"
    static let dockedBody = "Check that your monitors are arranged the way you like them. "
        + "TotalRekall will remember it."
    static let undockedTitle = "Name your desk"
    static let undockedBody = "TotalRekall will ask you to name the desk when you connect to it."
    static let continueTitle = "Continue"
    static let continueHint = "Goes to the last step, naming this desk"
    static let saveTitle = "Save"
    static let saveHint = "Saves the desk name and the way your monitors are arranged"
    static let undockedDoneTitle = "Done"
    static let undockedDoneHint = "Closes this window"
}
