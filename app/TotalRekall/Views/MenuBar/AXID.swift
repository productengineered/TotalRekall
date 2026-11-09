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
    }
}
