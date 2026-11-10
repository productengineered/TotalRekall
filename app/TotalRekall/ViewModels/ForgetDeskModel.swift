// ForgetDeskModel.swift
// State for the Forget Desk confirmation window. Cancel (button, Return, Esc, Cmd-W, close button) never
// forgets; only an explicit Forget Desk click does. Both paths are idempotent, so a button followed by the
// window's close path cannot fire twice.

import Foundation
import Observation

@MainActor
@Observable
final class ForgetDeskModel {
    let deskName: String
    private(set) var isFinished = false
    private let onForget: @MainActor () -> Void
    private let onCancel: @MainActor () -> Void

    init(deskName: String,
         onForget: @escaping @MainActor () -> Void,
         onCancel: @escaping @MainActor () -> Void = {}) {
        self.deskName = deskName
        self.onForget = onForget
        self.onCancel = onCancel
    }

    var title: String { "Forget \u{201C}\(deskName)\u{201D}?" }
    let body = "TotalRekall will stop restoring windows on this desk. "
        + "It will ask you to name it again the next time you connect these monitors."

    /// Only the Forget Desk button calls this.
    func forget() {
        guard !isFinished else { return }
        isFinished = true
        onForget()
    }

    /// Cancel button / Return / Esc / Cmd-W / close button.
    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        onCancel()
    }
}
