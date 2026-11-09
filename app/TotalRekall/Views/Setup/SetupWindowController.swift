// SetupWindowController.swift
// AppKit host for the setup window: one reused, non-modal, non-resizable window.
// Wiring it to launch / revocation / the menu lives in the app delegate.

import AppKit
import SwiftUI

final class SetupWindow: NSWindow {
    var onCancel: (@MainActor () -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// An accessory (LSUIElement) app has no main menu, so nothing maps Cmd-W to performClose.
    /// Handle it here or EARS-S3-016 silently fails.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            onCancel?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    static let contentWidth: CGFloat = 420

    private let model: SetupViewModel
    private var window: SetupWindow?
    private var hosting: NSHostingController<SetupView>?
    /// The one content height every state uses; re-measured each time the window is shown.
    private(set) var fixedContentHeight: CGFloat?

    init(model: SetupViewModel) {
        self.model = model
        super.init()
        model.onPresent = { [weak self] in self?.present() }
        model.onClose = { [weak self] in self?.close() }
    }

    var isShown: Bool { window?.isVisible == true }

    /// Shows the window and activates the accessory app.
    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        applyFixedSize()
        if !window.isVisible { window.center() }
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Fronts the window above System Settings without taking focus (the grant flip).
    func bringForwardWithoutActivating() {
        window?.orderFrontRegardless()
    }

    func close() {
        window?.close()
    }

    /// What the view model's `onPresent` does: a grant fronts quietly; everything else activates.
    private func present() {
        if isShown, model.state == .granted {
            bringForwardWithoutActivating()
        } else {
            show()
        }
    }

    private func makeWindow() -> SetupWindow {
        let hosting = NSHostingController(rootView: SetupView(model: model))
        hosting.sizingOptions = []   // the controller resizes explicitly so the top edge stays put
        let window = SetupWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.title = "Set Up Total Rekall"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.zoomButton)?.isEnabled = false   // zoom off, close + minimize on
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.setAccessibilityIdentifier(AXID.Setup.window)
        window.delegate = self
        window.onCancel = { [weak self] in self?.handleCancel() }
        self.hosting = hosting
        return window
    }

    private func handleCancel() {
        if model.state == .granted { model.done() } else { model.skip() }
    }

    func windowWillClose(_ notification: Notification) {
        handleCancel()
    }

    // MARK: Sizing

    /// Every state is shown in the same window: the tallest variant's fitted height, measured at show time
    /// (so it follows the current fonts / Dynamic Type). Nothing resizes on a state change.
    static func maxHeight(of variants: [SetupCopy], measure: (SetupCopy) -> CGFloat) -> CGFloat {
        variants.map(measure).max() ?? 0
    }

    /// Every state x reason combination the view can render.
    static func allVariants(paneName: String) -> [SetupCopy] {
        let states: [SetupState] = [.needsPermission(.firstRun), .needsPermission(.revoked), .waitingForGrant,
                                    .relaunchSuggested, .granted]
        return states.flatMap { state in
            [SetupReason.firstRun, .revoked].map { SetupCopy(state: state, reason: $0, paneName: paneName) }
        }
    }

    /// The tallest fitted content height across all variants at `contentWidth`.
    static func fixedContentHeight(model: SetupViewModel) -> CGFloat {
        let probe = NSHostingController(rootView: SetupView(model: model))
        return maxHeight(of: allVariants(paneName: model.paneName)) { copy in
            probe.rootView = SetupView(model: model, copyOverride: copy)
            return ceil(probe.sizeThatFits(in: CGSize(width: contentWidth, height: .greatestFiniteMagnitude)).height)
        }
    }

    private func applyFixedSize() {
        guard let window, let hosting else { return }
        let height = Self.fixedContentHeight(model: model)
        guard height > 0 else { return }
        if height != fixedContentHeight || hosting.rootView.contentHeight != height {
            fixedContentHeight = height
            hosting.rootView = SetupView(model: model, contentHeight: height)
        }
        let contentRect = NSRect(origin: .zero, size: CGSize(width: Self.contentWidth, height: height))
        var frame = window.frameRect(forContentRect: contentRect)
        if window.isVisible {
            frame.origin.x = window.frame.origin.x
            frame.origin.y = window.frame.maxY - frame.height
        }
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true, animate: false)
    }

    /// The window's current frame (nil before first show). Exposed for tests.
    var windowFrame: NSRect? { window?.frame }
}
