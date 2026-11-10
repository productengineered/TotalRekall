// ForgetDeskWindowController.swift
// Hosts the Forget Desk confirmation in a DeskNameWindow (same window class, style mask, opaque
// background and floating level as the Save this desk? / Rename windows).

import AppKit
import SwiftUI

@MainActor
protocol ForgetDeskPresenting: AnyObject {
    var isShown: Bool { get }
    func show(model: ForgetDeskModel)
    func close()
}

@MainActor
final class ForgetDeskWindowController: NSObject, NSWindowDelegate, ForgetDeskPresenting {
    private var window: DeskNameWindow?
    private var model: ForgetDeskModel?

    var isShown: Bool { window?.isVisible == true }
    /// For tests: the hosted window's level.
    var windowLevel: NSWindow.Level? { window?.level }

    func show(model: ForgetDeskModel) {
        let wasVisible = isShown
        // A second request while one is open replaces it; the old one counts as cancelled.
        if wasVisible { self.model?.cancel() }
        self.model = model
        let width = DeskNameWindowController.contentWidth
        let hosting = NSHostingController(rootView: ForgetDeskView(model: model))
        hosting.sizingOptions = []
        let height = ceil(hosting.sizeThatFits(in: CGSize(width: width,
                                                          height: .greatestFiniteMagnitude)).height)
        hosting.rootView = ForgetDeskView(model: model, contentHeight: height)

        let window = self.window ?? makeWindow()
        self.window = window
        window.contentViewController = hosting
        window.title = "Forget Desk"
        window.setContentSize(CGSize(width: width, height: height))
        window.onCancel = { [weak model] in model?.cancel() }
        if !wasVisible {
            window.center()
            NSApplication.shared.activate()
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> DeskNameWindow {
        let window = DeskNameWindow(contentRect: .zero,
                                    styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                                    backing: .buffered,
                                    defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.setAccessibilityIdentifier(AXID.Desk.forgetAlert)
        window.delegate = self
        return window
    }

    /// The close button. Idempotent: after Forget Desk / Cancel the model has already finished.
    func windowWillClose(_ notification: Notification) {
        model?.cancel()
    }
}
