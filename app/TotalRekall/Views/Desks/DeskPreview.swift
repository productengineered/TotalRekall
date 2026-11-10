// DeskPreview.swift
// REC-6, DEBUG only: launch arguments that raise the "Save this desk?" window or the Rename window
// without real monitors. They run on fake collaborators, so they never write the real desk store,
// snapshots or the gate.
//   -TRSimulateNewDesk                 raise the Save this desk? prompt through the real coordinator
//   -TRDeskPreview save|rename         open that window directly

#if DEBUG
import AppKit
import Foundation

/// A desk store that lives in memory only.
@MainActor
final class PreviewDeskActions: DeskActions {
    func deskSummaries() async -> [DeskSummary] {
        [DeskSummary(id: "preview-studio", name: "Studio", isCurrent: false),
         DeskSummary(id: DeskPreviewLauncher.simulatedKey, name: "Desk 2", isCurrent: true)]
    }
    func deskNames() async -> [String] { await deskSummaries().map(\.name) }
    func renameDesk(_ key: String, to name: String) async -> DeskRenameResult { .renamed(name) }
    func saveDeskArrangement(_ key: String) async -> DeskArrangementResult { .saved(windowCount: 0) }
    func forgetDesk(_ key: String) async -> Bool { false }
}

@MainActor
enum DeskPreviewLauncher {
    static let simulatedKey = "preview-simulated-desk"
    private static var coordinator: NewDeskPromptCoordinator?
    private static var actions: PreviewDeskActions?

    /// The coordinator on fake collaborators: in-memory actions, every gating condition satisfied.
    static func makeCoordinator(prompt: DeskNamePresenting, rename: DeskNamePresenting) -> NewDeskPromptCoordinator {
        let conditions = NewDeskPromptCoordinator.Conditions(
            isSetupOpen: { false }, screensAwakeAndUnlocked: { true },
            isAccessibilityTrusted: { true }, isCycleRunning: { false },
            liveDeskKey: { simulatedKey })
        let fake = PreviewDeskActions()
        actions = fake
        return NewDeskPromptCoordinator(actions: fake, prompt: prompt, rename: rename, conditions: conditions)
    }

    /// Opens a preview window when a launch argument asks for it. Returns true if it did.
    @discardableResult
    static func runIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        let mode: String
        if let flag = arguments.firstIndex(of: "-TRDeskPreview"), flag + 1 < arguments.count {
            mode = arguments[flag + 1]
        } else if arguments.contains("-TRSimulateNewDesk") {
            mode = "save"
        } else {
            return false
        }
        guard mode == "save" || mode == "rename" else { return false }
        let coordinator = makeCoordinator(prompt: DeskNameWindowController(), rename: DeskNameWindowController())
        self.coordinator = coordinator
        if mode == "rename" {
            coordinator.presentRename(for: DeskSummary(id: simulatedKey, name: "Desk 2", isCurrent: true))
        } else {
            coordinator.deskDiscovered(NewDeskEvent(key: simulatedKey, name: "Desk 2"))
        }
        return true
    }
}
#endif
