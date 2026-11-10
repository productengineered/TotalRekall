// NewDeskPromptCoordinator.swift
// Decides WHEN the "Save this desk?" window appears and owns the Rename window (named desks).
//
// Rules (named-desks-spec D5, D9, D10; design review cuts/binding notes):
//   - Only a desk announced by the new-desk event THIS RUN is ever prompted, and only once (in-memory
//     handled set; nothing is persisted).
//   - Shown only when setup is closed, screens are awake and unlocked, Accessibility is trusted and no
//     cycle is running. Otherwise it waits: a bounded retry covers the moment right after the event
//     (the cycle is still finishing), and `reevaluate()` runs when setup closes or Accessibility returns.
//   - The prompt is also re-checked the moment the gate reopens after a display-change cycle (the
//     AppDelegate wires `AutomationController.onGateReopened` to `reevaluate()`): the event fires INSIDE
//     the dock-time cycle and a follow-up cycle can hold the gate closed longer than the retry lasts.
//   - A second event while the window is open is ignored; the current desk is re-checked at the next
//     re-evaluation. Nothing is queued.
//   - Save / Rename act on the desk key captured when the window was built, never on "the current desk".
//   - Not Now, Esc, Cmd-W and close keep the default name and touch nothing else: this class has no
//     access to the snapshot gate, so a dismissed prompt can never close it.

import Foundation

@MainActor
final class NewDeskPromptCoordinator {
    struct Conditions {
        var isSetupOpen: () -> Bool
        var screensAwakeAndUnlocked: () -> Bool
        var isAccessibilityTrusted: () -> Bool
        var isCycleRunning: () -> Bool
        /// Key of the desk whose monitors are connected right now (nil for the built-in display alone).
        var liveDeskKey: () -> String?

        /// The production gating closures, built once so AppDelegate and the wiring test share them.
        /// The gate is closed for the whole display-change cycle (settle, fix, restore).
        @MainActor
        static func live(gate: SnapshotGate,
                         accessibility: AccessibilityStatusProviding,
                         isSetupOpen: @escaping () -> Bool,
                         sessionLocked: @escaping () -> Bool? = { SessionLockHint.isLocked() },
                         liveDeskKey: @escaping () -> String?) -> Conditions {
            Conditions(
                isSetupOpen: isSetupOpen,
                screensAwakeAndUnlocked: { !gate.holds.contains(.screensAsleep) && sessionLocked() != true },
                isAccessibilityTrusted: { accessibility.isTrusted },
                isCycleRunning: { !gate.isOpen },
                liveDeskKey: liveDeskKey)
        }
    }

    private let actions: DeskActions
    private let prompt: DeskNamePresenting
    private let rename: DeskNamePresenting
    private let conditions: Conditions
    private let retryDelay: Duration
    private let maxRetries: Int
    private let diagnostics: DiagnosticsRecording?
    private let sleep: @Sendable (Duration) async throws -> Void
    /// Last blocker written to the diary, so a polling retry logs a change, not every tick.
    private var lastLoggedBlocker: String?

    /// Desks announced by the new-desk event this run (key -> name at announcement).
    private var discovered: [String: String] = [:]
    /// Desks that were saved, dismissed, or handled by the setup step. Never persisted.
    private(set) var handled: Set<String> = []
    private var isPreparing = false
    private var retry: Task<Void, Never>?
    /// Called after a rename or a saved arrangement so the Desks menu and status line refresh.
    var onDesksChanged: (@MainActor () async -> Void)?

    init(actions: DeskActions,
         prompt: DeskNamePresenting,
         rename: DeskNamePresenting,
         conditions: Conditions,
         retryDelay: Duration = .seconds(2),
         maxRetries: Int = 15,
         diagnostics: DiagnosticsRecording? = nil,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
        self.diagnostics = diagnostics
        self.actions = actions
        self.prompt = prompt
        self.rename = rename
        self.conditions = conditions
        self.retryDelay = retryDelay
        self.maxRetries = maxRetries
    }

    // MARK: Inputs

    /// The new-desk event. Fire-and-forget: never awaits UI and never touches the gate.
    func deskDiscovered(_ event: NewDeskEvent) {
        discovered[event.key] = event.name
        reevaluate()
    }

    /// The setup step handled this desk (D9), or the prompt did: never ask again this run.
    func markHandled(_ key: String) {
        handled.insert(key)
    }

    /// The user forgot this desk: it is a new desk again, so a reconnect this run may prompt once more
    /// (never shown twice for the same desk unless the user forgets it).
    func deskForgotten(_ key: String) {
        handled.remove(key)
        discovered[key] = nil
    }

    /// Re-checks the current desk. Called on the event, when setup closes, when Accessibility returns,
    /// and by the bounded retry.
    func reevaluate() {
        guard let key = promptableKey() else { return }
        if let blocker = blocker() {
            if blocker != lastLoggedBlocker {
                lastLoggedBlocker = blocker
                diagnostics?.record(DiagnosticsEvent(.setup, "desk-prompt-deferred", fields: ["blocker": .string(blocker)]))
            }
            scheduleRetry()
            return
        }
        retry?.cancel()
        retry = nil
        present(key: key)
    }

    // MARK: Prompt

    private func promptableKey() -> String? {
        guard let key = conditions.liveDeskKey(), discovered[key] != nil, !handled.contains(key) else { return nil }
        return key
    }

    /// Why the prompt cannot show right now (a fixed code, never free text), or nil when it can.
    private func blocker() -> String? {
        if prompt.isShown { return "window-open" }
        if isPreparing { return "preparing" }
        if conditions.isSetupOpen() { return "setup-open" }
        if !conditions.screensAwakeAndUnlocked() { return "screens-asleep-or-locked" }
        if !conditions.isAccessibilityTrusted() { return "accessibility-missing" }
        if conditions.isCycleRunning() { return "cycle-running" }
        return nil
    }

    private func canShowNow() -> Bool { blocker() == nil }

    private func scheduleRetry() {
        guard retry == nil, !prompt.isShown, maxRetries > 0 else { return }
        let delay = retryDelay
        let limit = maxRetries
        let sleep = self.sleep
        retry = Task { [weak self] in
            for _ in 0..<limit {
                try? await sleep(delay)
                guard !Task.isCancelled, let self else { return }
                guard self.promptableKey() != nil else { break }
                if self.canShowNow() {
                    self.retry = nil
                    self.reevaluate()
                    return
                }
            }
            self?.retry = nil
        }
    }

    private func present(key: String) {
        isPreparing = true
        Task { [weak self] in
            guard let self else { return }
            let summaries = await actions.deskSummaries()
            isPreparing = false
            // Everything may have changed during the await: check again before showing.
            guard promptableKey() == key, canShowNow() else {
                scheduleRetryIfStillWanted()
                return
            }
            let name = summaries.first(where: { $0.id == key })?.name ?? discovered[key] ?? "Desk"
            let others = summaries.filter { $0.id != key }.map(\.name)
            let model = DeskNameModel(
                mode: .newDesk, initialName: name, otherNames: others,
                onSave: { [weak self] newName in self?.finishSave(key: key, name: newName) },
                onCancel: { [weak self] in self?.finishDismiss(key: key) })
            // Shown means handled: whichever way the window ends (Save, Not Now, close), this desk is
            // not asked again this run unless the user forgets it.
            handled.insert(key)
            lastLoggedBlocker = nil
            diagnostics?.record(DiagnosticsEvent(.setup, "desk-prompt-shown"))
            prompt.show(model: model)
        }
    }

    private func scheduleRetryIfStillWanted() {
        if promptableKey() != nil { reevaluate() }
    }

    /// Save: name the captured desk, then learn its arrangement and snapshot now (the store only does
    /// that if the live desk is still `key`).
    private func finishSave(key: String, name: String) {
        handled.insert(key)
        prompt.close()
        Task { [actions, weak self] in
            guard case .renamed = await actions.renameDesk(key, to: name) else { return }
            _ = await actions.saveDeskArrangement(key)
            await self?.onDesksChanged?()
        }
    }

    /// Not Now / Esc / Cmd-W / close: keep the default name; the desk is handled; nothing else changes.
    private func finishDismiss(key: String) {
        handled.insert(key)
        prompt.close()
    }

    // MARK: Rename

    /// Desks > Rename…: opens the Rename window for the desk captured now.
    func presentRename(for desk: DeskSummary) {
        Task { [weak self] in
            guard let self else { return }
            let summaries = await actions.deskSummaries()
            let others = summaries.filter { $0.id != desk.id }.map(\.name)
            let current = summaries.first(where: { $0.id == desk.id })?.name ?? desk.name
            let key = desk.id
            let model = DeskNameModel(
                mode: .rename, initialName: current, otherNames: others,
                onSave: { [weak self] newName in self?.finishRename(key: key, from: current, to: newName) },
                onCancel: { [weak self] in self?.rename.close() })
            rename.show(model: model)
        }
    }

    private func finishRename(key: String, from old: String, to name: String) {
        rename.close()
        guard name != old else { return }   // unchanged name: nothing to do
        Task { [actions, weak self] in
            _ = await actions.renameDesk(key, to: name)
            await self?.onDesksChanged?()
        }
    }
}
