// SetupPreview.swift
// DEBUG-only seams for the setup window: SwiftUI previews and launch arguments that open it without
// touching real Accessibility permission.
//   -TRSetupPreviewState first-run|revoked|waiting|relaunch|done   open the window in a forced state
//   -TRSetupPreviewAutoGrant                                       fake permission: click "Open System
//       Settings" (or Skip/close as usual) and ~4 s later the grant flips live, with no TCC change

#if DEBUG
import AppKit
import Foundation

/// A permission source that never touches the system.
@MainActor
final class PreviewAccessibilityStatus: AccessibilityStatusProviding {
    var isTrusted = false
    var onChange: (@MainActor (Bool) -> Void)?
    /// When set, "opening System Settings" schedules a grant after this delay.
    var grantAfterOpen: Duration?

    func refresh() {}

    func openAccessibilitySettings() {
        guard let delay = grantAfterOpen else { return }
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            self?.isTrusted = true
            self?.onChange?(true)
        }
    }
}

@MainActor
private final class PreviewSetupStore: SetupCompletionStoring {
    var isCompleted = false
    func markCompleted() { isCompleted = true }
}

private struct PreviewDiagnostics: DiagnosticsRecording {
    nonisolated func record(_ event: DiagnosticsEvent) {}
}

extension SetupViewModel {
    /// A model forced into `state` with fake collaborators and no timers (previews, preview launch args).
    static func preview(_ state: SetupState) -> SetupViewModel {
        let model = makePreviewModel(status: PreviewAccessibilityStatus())
        model.forcePreviewState(state)
        return model
    }

    fileprivate static func makePreviewModel(status: PreviewAccessibilityStatus) -> SetupViewModel {
        SetupViewModel(
            status: status, store: PreviewSetupStore(), diagnostics: PreviewDiagnostics(), relaunchAction: {}
        )
    }
}

@MainActor
enum SetupPreviewLauncher {
    private static var controller: SetupWindowController?
    private static var model: SetupViewModel?
    private static var status: PreviewAccessibilityStatus?

    static func state(named name: String) -> SetupState? {
        switch name {
        case "first-run": .needsPermission(.firstRun)
        case "revoked": .needsPermission(.revoked)
        case "waiting": .waitingForGrant
        case "relaunch": .relaunchSuggested
        case "done": .granted
        default: nil
        }
    }

    /// Opens the preview window when a launch argument asks for it. Returns true if it did.
    @discardableResult
    static func runIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        if arguments.contains("-TRSetupPreviewAutoGrant") {
            let fake = PreviewAccessibilityStatus()
            fake.grantAfterOpen = .seconds(4)
            let model = SetupViewModel.makePreviewModel(status: fake)
            fake.onChange = { [weak model] trusted in model?.trustDidChange(trusted) }
            retain(model, fake)
            model.evaluateLaunch()
            return true
        }
        if let flag = arguments.firstIndex(of: "-TRSetupPreviewState"), flag + 1 < arguments.count,
           let forced = state(named: arguments[flag + 1]) {
            let fake = PreviewAccessibilityStatus()
            let model = SetupViewModel.makePreviewModel(status: fake)
            retain(model, fake)
            model.forcePreviewState(forced)
            controller?.show()
            return true
        }
        return false
    }

    private static func retain(_ model: SetupViewModel, _ status: PreviewAccessibilityStatus) {
        self.model = model
        self.status = status
        controller = SetupWindowController(model: model)
    }
}
#endif
