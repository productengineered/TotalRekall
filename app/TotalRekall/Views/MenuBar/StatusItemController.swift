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
    /// "Rename…" in the Desks submenu: opens the Rename window for the current desk (connected by the
    /// rename window controller; a no-op until then).
    var onRenameDesk: (@MainActor (DeskSummary) -> Void)?
    /// Hosts the Forget Desk… confirmation (an opaque window like the other TotalRekall windows).
    /// Injectable for tests.
    var forgetPresenter: ForgetDeskPresenting = ForgetDeskWindowController()
    private weak var statusLineItem: NSMenuItem?
    private weak var desksParentItem: NSMenuItem?
    private var isMenuOpen = false

    /// AXID.swift is shared with the parallel setup work; move this constant there with the next AXID edit.

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
        statusItem.button?.setAccessibilityLabel("TotalRekall")
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
        button.toolTip = "TotalRekall: \(value)"
        let badge = StatusIcon.badge(iconName: viewModel.iconName, animates: viewModel.iconAnimates)
        animator?.setWorking(badge == .working)
        let frame = animator?.mode == .animating ? animator?.frame : nil
        button.image = StatusIcon.image(badge: badge, description: "TotalRekall", workingFrame: frame)
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        onMenuWillOpen?()
        isMenuOpen = true
        rebuild(menu)
        // The list is cached; refresh it now and update the open menu in place (no I/O on open).
        Task { @MainActor [weak self] in
            await self?.viewModel.refreshDesks()
            self?.refreshOpenDesks()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        viewModel.clearShownNotices()
    }

    /// Re-renders the Desks submenu and the status line after the desk list refreshed under an open menu.
    private func refreshOpenDesks() {
        guard isMenuOpen else { return }
        statusLineItem?.title = viewModel.statusLine
        statusLineItem?.setAccessibilityLabel(viewModel.statusLine)
        desksParentItem?.submenu = DesksMenuBuilder.makeSubmenu(
            state: viewModel.desksMenuState, target: self, rename: #selector(renameDesk),
            saveArrangement: #selector(saveDeskArrangement), forget: #selector(forgetDesk))
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
            let line = infoRow(vm.statusLine, id: AXID.Menu.statusLine)
            statusLineItem = line
            menu.addItem(line)
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

        desksParentItem = nil
        if !vm.showsAccessibilityWarning {
            let desksItems = DesksMenuBuilder.items(
                state: vm.desksMenuState, target: self, rename: #selector(renameDesk),
                saveArrangement: #selector(saveDeskArrangement), forget: #selector(forgetDesk))
            desksItems.forEach { menu.addItem($0) }
            desksParentItem = desksItems.first
            if vm.desksMenuState.notice != nil { vm.markDesksNoticeShown() }
        }

        let login = item("Launch at Login", id: AXID.Menu.launchAtLogin, action: #selector(toggleLaunchAtLogin))
        login.state = launchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        menu.addItem(item("Quit TotalRekall", id: AXID.Menu.quit, action: #selector(quit), key: "q"))
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
            if let desk = detail.deskName {
                sub.addItem(infoRow("Desk: \(desk)", id: AXID.Menu.lastRestoreDesk))
            }
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

    @objc private func renameDesk() {
        guard let desk = viewModel.currentDesk else { return }
        onRenameDesk?(desk)
    }

    @objc private func saveDeskArrangement() { Task { await viewModel.saveCurrentArrangement() } }

    @objc private func forgetDesk() {
        guard viewModel.isForgetDeskEnabled, let desk = viewModel.currentDesk else { return }
        // An accessory app is not active when a menu item is clicked; bring the window to the front.
        NSApp.activate()
        let model = ForgetDeskModel(
            deskName: desk.name,
            onForget: { [weak self] in
                self?.forgetPresenter.close()
                guard let self else { return }
                Task { _ = await self.viewModel.forgetDesk(desk.id) }
            },
            onCancel: { [weak self] in self?.forgetPresenter.close() })
        forgetPresenter.show(model: model)
    }

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

// MARK: - Desks submenu (named desks)

/// Everything the Desks submenu shows, built from the view model's cached state.
struct DesksMenuState: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let id: String
        let name: String
        let isCurrent: Bool
    }

    let desks: [Entry]
    let isTrusted: Bool
    /// A restore or monitor fix is running.
    let isBusy: Bool
    /// One-shot, e.g. "Saved this arrangement for Studio".
    let notice: String?

    var current: Entry? { desks.first { $0.isCurrent } }
}

@MainActor
enum DesksMenuBuilder {
    /// The "Desks" parent followed by the optional indented notice.
    static func items(state: DesksMenuState, target: AnyObject, rename: Selector,
                      saveArrangement: Selector, forget: Selector) -> [NSMenuItem] {
        let parent = NSMenuItem(title: "Desks", action: nil, keyEquivalent: "")
        parent.setAccessibilityIdentifier(AXID.Menu.desks)
        parent.isEnabled = true  // an enabled parent opens the submenu on hover
        parent.submenu = makeSubmenu(state: state, target: target, rename: rename,
                                     saveArrangement: saveArrangement, forget: forget)
        guard let notice = state.notice else { return [parent] }
        let noticeItem = NSMenuItem(title: notice, action: nil, keyEquivalent: "")
        noticeItem.setAccessibilityIdentifier(AXID.Menu.desksNotice)
        noticeItem.setAccessibilityLabel(notice)
        noticeItem.indentationLevel = 1
        noticeItem.isEnabled = false
        return [parent, noticeItem]
    }

    static func makeSubmenu(state: DesksMenuState, target: AnyObject, rename: Selector,
                            saveArrangement: Selector, forget: Selector) -> NSMenu {
        let submenu = NSMenu(title: "Desks")
        submenu.autoenablesItems = false
        if state.desks.isEmpty {
            submenu.addItem(infoLine("No desks yet", id: AXID.Menu.desksEmpty, checked: false))
        } else {
            for (index, desk) in state.desks.enumerated() {
                submenu.addItem(infoLine(desk.name, id: "\(AXID.Menu.desksItem).\(index)", checked: desk.isCurrent))
            }
        }
        submenu.addItem(.separator())
        let hasCurrent = state.current != nil
        submenu.addItem(actionItem("Rename…", id: AXID.Menu.desksRename, action: rename, target: target,
                                   enabled: hasCurrent))
        submenu.addItem(actionItem("Save Current Arrangement", id: AXID.Menu.desksSaveArrangement,
                                   action: saveArrangement, target: target,
                                   enabled: hasCurrent && state.isTrusted && !state.isBusy))
        submenu.addItem(actionItem("Forget Desk…", id: AXID.Menu.desksForget, action: forget, target: target,
                                   enabled: hasCurrent && !state.isBusy))
        return submenu
    }

    private static func infoLine(_ title: String, id: String, checked: Bool) -> NSMenuItem {
        let line = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        line.isEnabled = false
        line.state = checked ? .on : .off
        line.setAccessibilityIdentifier(id)
        line.setAccessibilityLabel(title)
        return line
    }

    private static func actionItem(_ title: String, id: String, action: Selector, target: AnyObject,
                                   enabled: Bool) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = target
        menuItem.isEnabled = enabled
        menuItem.setAccessibilityIdentifier(id)
        return menuItem
    }
}
