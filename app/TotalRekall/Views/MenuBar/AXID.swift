import Foundation

/// Shared accessibility-identifier namespace (stable UAT selectors; not VoiceOver labels).
enum AXID {
    enum Menu {
        static let statusItem = "menu.statusItem"
        static let accessibilityWarning = "menu.accessibilityWarning"
        static let relaunchForAccessibility = "menu.relaunchForAccessibility"
        static let statusLine = "menu.statusLine"
        static let lastResult = "menu.lastResult"
        static let lastRestoreTrigger = "menu.lastRestore.trigger"
        static let lastRestoreMonitors = "menu.lastRestore.monitors"
        static let lastRestoreDesk = "menu.lastRestore.desk"
        static let lastRestoreApp = "menu.lastRestore.app"
        static let lastRestoreMore = "menu.lastRestore.more"
        static let lastRestoreUnavailable = "menu.lastRestore.unavailable"
        static let saveSnapshot = "menu.saveSnapshotNow"
        static let snapshotNotice = "menu.snapshotNotice"
        static let restoreNow = "menu.restoreNow"
        static let fixMonitors = "menu.fixMonitors"
        static let revealLog = "menu.revealRestoreLog"
        static let exportDiagnostics = "menu.exportDiagnostics"
        static let exportNotice = "menu.exportNotice"
        static let launchAtLogin = "menu.launchAtLogin"
        static let quit = "menu.quit"
        // Desks submenu (named desks). Item lines append ".0", ".1", ...
        static let desks = "menu.desks"
        static let desksNotice = "menu.desks.notice"
        static let desksItem = "menu.desks.item"
        static let desksEmpty = "menu.desks.empty"
        static let desksRename = "menu.desks.rename"
        static let desksSaveArrangement = "menu.desks.saveArrangement"
        static let desksForget = "menu.desks.forget"
    }
}

extension AXID {
    enum Setup {
        static let window = "setup.window"
        static let title = "setup.title"
        static let body = "setup.body"
        static let permissionRow = "setup.permissionRow"
        static let badge = "setup.badge"
        static let helper = "setup.helper"
        static let primaryButton = "setup.primaryButton"
        static let secondaryButton = "setup.secondaryButton"
        static let relaunchLink = "setup.relaunchLink"
        static let skipButton = "setup.skipButton"
        static let footer = "setup.footer"
        // Name-this-desk step (named desks).
        static let deskNameField = "setup.deskNameField"
        static let deskMessage = "setup.deskMessage"
    }

    /// The Save this desk? / Rename windows and the Forget Desk alert (named desks).
    enum Desk {
        static let window = "desk.window"
        static let title = "desk.title"
        static let body = "desk.body"
        static let nameField = "desk.nameField"
        static let message = "desk.message"
        static let confirmButton = "desk.confirmButton"
        static let cancelButton = "desk.cancelButton"
        static let forgetAlert = "desk.forgetAlert"
        static let forgetConfirmButton = "desk.forgetConfirmButton"
        static let forgetCancelButton = "desk.forgetCancelButton"
    }
}
