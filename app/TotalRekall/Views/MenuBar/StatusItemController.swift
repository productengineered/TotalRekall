import AppKit
import Observation

/// Controls Launch at Login. LaunchAtLoginMenuAdapter wraps the real LaunchAtLoginService.
@MainActor
protocol LaunchAtLoginControlling: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool)
}

/// Owns the NSStatusItem and its NSMenu; renders MenuBarViewModel and forwards actions.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let viewModel: MenuBarViewModel
    private let launchAtLogin: LaunchAtLoginControlling
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var animator: StatusIconAnimator?
    private var terminationObserver: NSObjectProtocol?
    /// Called before each menu rebuild so opening the menu re-checks Accessibility trust.
    var onMenuWillOpen: (@MainActor () -> Void)?
    /// The "Accessibility access needed" item opens (or fronts) the setup window.
    var onShowSetup: (@MainActor () -> Void)?

    private static let accessibilityPaneURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )

    init(viewModel: MenuBarViewModel, launchAtLogin: LaunchAtLoginControlling) {
        self.viewModel = viewModel
        self.launchAtLogin = launchAtLogin
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.setAccessibilityIdentifier(AXID.Menu.statusItem)
        statusItem.button?.setAccessibilityLabel("Total Rekall")
        animator = StatusIconAnimator { [weak self] in self?.refreshIcon() }
        // Never leave the animation timer running as the app quits.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.animator?.shutDown() }
        }
        refreshIcon()
        observe()
    }

    // MARK: Observation

    private func observe() {
        withObservationTracking {
            _ = viewModel.iconName
            _ = viewModel.iconAnimates
            _ = viewModel.accessibilityValue
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshIcon()
                self?.observe()
            }
        }
    }

    // MARK: Icon

    /// Working animates via StatusIconAnimator; with Reduce Motion on it stays the static working badge.
    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        let value = viewModel.accessibilityValue
        button.setAccessibilityValue(value)
        button.toolTip = "Total Rekall: \(value)"
        let badge = StatusIcon.badge(iconName: viewModel.iconName, animates: viewModel.iconAnimates)
        animator?.setWorking(badge == .working)
        let frame = animator?.mode == .animating ? animator?.frame : nil
        button.image = StatusIcon.image(badge: badge, description: "Total Rekall", workingFrame: frame)
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        onMenuWillOpen?()
        rebuild(menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        viewModel.clearShownNotices()
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let vm = viewModel

        if vm.showsAccessibilityWarning {
            menu.addItem(item(vm.statusLine, id: AXID.Menu.accessibilityWarning,
                              action: #selector(openAccessibilitySettings)))
            // macOS can keep a stale trust value in a running process after a re-grant.
            let relaunch = item(MenuBarViewModel.relaunchForAccessibilityTitle,
                                id: AXID.Menu.relaunchForAccessibility, action: #selector(relaunchApp))
            relaunch.indentationLevel = 1
            menu.addItem(relaunch)
        } else {
            menu.addItem(infoRow(vm.statusLine, id: AXID.Menu.statusLine))
        }
        addLastRestore(to: menu, now: Date())
        menu.addItem(.separator())

        menu.addItem(item("Save Snapshot Now", id: AXID.Menu.saveSnapshot,
                          action: #selector(saveNow), enabled: vm.isSaveEnabled))
        if let notice = vm.snapshotNotice {
            // Informational, disabled: explains why the last Save Snapshot Now was refused.
            let noticeItem = item(notice, id: AXID.Menu.snapshotNotice, action: nil)
            noticeItem.indentationLevel = 1
            menu.addItem(noticeItem)
        }
        menu.addItem(item("Restore Now", id: AXID.Menu.restoreNow,
                          action: #selector(restoreNow), enabled: vm.isRestoreEnabled))
        menu.addItem(item("Fix Monitors", id: AXID.Menu.fixMonitors,
                          action: #selector(fixMonitors), enabled: vm.isFixMonitorsEnabled))
        menu.addItem(item("Reveal Restore Log", id: AXID.Menu.revealLog,
                          action: #selector(revealLog), enabled: vm.isRevealLogEnabled))
        let exportItem = item(vm.exportTitle, id: AXID.Menu.exportDiagnostics,
                              action: #selector(exportDiagnostics), enabled: vm.isExportEnabled)
        exportItem.toolTip = "Saves a zip of diagnostics to the Desktop"
        exportItem.setAccessibilityLabel(vm.exportTitle)
        menu.addItem(exportItem)
        if let notice = vm.exportNotice {
            let noticeItem = item(notice, id: AXID.Menu.exportNotice, action: nil)
            noticeItem.indentationLevel = 1
            menu.addItem(noticeItem)
            vm.markExportNoticeShown()
        }
        menu.addItem(.separator())

        let login = item("Launch at Login", id: AXID.Menu.launchAtLogin, action: #selector(toggleLaunchAtLogin))
        login.state = launchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        menu.addItem(item("Quit Total Rekall", id: AXID.Menu.quit, action: #selector(quit), key: "q"))
    }

    /// "Last restore" line with a read-only per-app submenu, built from the view model's cache (no file I/O).
    private func addLastRestore(to menu: NSMenu, now: Date) {
        let vm = viewModel
        let parent = item(vm.lastResultLine(now: now), id: AXID.Menu.lastResult, action: nil)
        guard vm.hasLastRestore else {
            menu.addItem(parent)
            return
        }
        parent.isEnabled = true  // an enabled parent shows the arrow and opens on hover
        let sub = NSMenu()
        sub.autoenablesItems = false
        if vm.lastRestoreUnreadable {
            sub.addItem(infoRow("Details unavailable — use Reveal Restore Log", id: AXID.Menu.lastRestoreUnavailable))
        } else if let detail = vm.lastRestoreDetail {
            sub.addItem(infoRow(vm.triggerLine(detail, now: now), id: AXID.Menu.lastRestoreTrigger))
            if let monitors = detail.monitorLine {
                sub.addItem(infoRow(monitors, id: AXID.Menu.lastRestoreMonitors))
            }
            sub.addItem(.separator())
            let lines = detail.appLines.isEmpty ? ["No windows were moved"] : detail.appLines
            for (index, line) in lines.enumerated() {
                sub.addItem(infoRow(line, id: "\(AXID.Menu.lastRestoreApp).\(index)"))
            }
            if detail.overflowCount > 0 {
                sub.addItem(infoRow("and \(detail.overflowCount) more — see the restore log",
                                    id: AXID.Menu.lastRestoreMore))
            }
        }
        parent.submenu = sub
        menu.addItem(parent)
    }

    private func infoRow(_ title: String, id: String) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        row.isEnabled = false
        row.setAccessibilityIdentifier(id)
        row.setAccessibilityLabel(title)
        return row
    }

    private func item(_ title: String, id: String, action: Selector?, enabled: Bool = true,
                      key: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        menuItem.isEnabled = enabled && action != nil
        menuItem.setAccessibilityIdentifier(id)
        return menuItem
    }

    // MARK: Actions

    @objc private func openAccessibilitySettings() {
        if let onShowSetup {
            onShowSetup()
            return
        }
        if let url = Self.accessibilityPaneURL { NSWorkspace.shared.open(url) }
    }

    @objc private func saveNow() { Task { await viewModel.saveNow() } }
    @objc private func restoreNow() { Task { await viewModel.restoreNow() } }
    @objc private func fixMonitors() { Task { await viewModel.fixMonitors() } }

    @objc private func exportDiagnostics() { Task { await viewModel.exportDiagnostics() } }

    @objc private func revealLog() {
        guard let url = viewModel.restoreLogURLToReveal() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func toggleLaunchAtLogin() {
        launchAtLogin.setEnabled(!launchAtLogin.isEnabled)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func relaunchApp() { AppRelauncher().relaunch() }
}
