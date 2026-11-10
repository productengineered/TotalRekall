// DeskNameWindowController.swift
// AppKit host for the "Save this desk?" and Rename windows: a non-modal, non-resizable window in the
// setup window's style. The caller decides WHEN to show it (see NewDeskPromptCoordinator); this class
// only hosts. Use one instance per mode so showing one never orphans the other's model.

import AppKit
import SwiftUI

final class DeskNameWindow: NSWindow {
    var onCancel: (@MainActor () -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// An accessory (LSUIElement) app has no main menu, so Cmd-W needs handling here (as in SetupWindow).
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

/// What the prompt coordinator needs from a window host (a fake in tests).
@MainActor
protocol DeskNamePresenting: AnyObject {
    var isShown: Bool { get }
    func show(model: DeskNameModel)
    func close()
}

@MainActor
final class DeskNameWindowController: NSObject, NSWindowDelegate, DeskNamePresenting {
    static let contentWidth: CGFloat = 420

    private var window: DeskNameWindow?
    private var model: DeskNameModel?

    var isShown: Bool { window?.isVisible == true }
    /// For tests: the hosted window's level.
    var windowLevel: NSWindow.Level? { window?.level }

    /// Shows the window for `model`. Activates the app only when the window was not already visible,
    /// so a re-show never steals focus again.
    func show(model: DeskNameModel) {
        let wasVisible = isShown
        self.model = model
        let copy = DeskNameCopy(mode: model.mode)
        let hosting = NSHostingController(rootView: DeskNameView(model: model))
        hosting.sizingOptions = []
        let height = ceil(hosting.sizeThatFits(in: CGSize(width: Self.contentWidth,
                                                          height: .greatestFiniteMagnitude)).height)
        hosting.rootView = DeskNameView(model: model, contentHeight: height)

        let window = self.window ?? makeWindow()
        self.window = window
        window.contentViewController = hosting
        window.title = copy.windowTitle
        window.setContentSize(CGSize(width: Self.contentWidth, height: height))
        window.onCancel = { [weak model] in model?.cancel() }
        if !wasVisible {
            window.center()
            NSApplication.shared.activate()
        }
        window.makeKeyAndOrderFront(nil)
        // The prompt opens when a dock-time cycle ends, with another app frontmost. An accessory app's
        // plain makeKeyAndOrderFront can leave the window BEHIND that app (it did in the user's test:
        // on screen at z-index 12, under Chrome and cmux). Order it in front regardless of activation.
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
        window.level = .floating   // a time-sensitive prompt: stays above other apps' windows until answered
        window.setAccessibilityIdentifier(AXID.Desk.window)
        window.delegate = self
        return window
    }

    /// The close button. Idempotent: after Save / Not Now the model has already finished.
    func windowWillClose(_ notification: Notification) {
        model?.cancel()
    }
}
