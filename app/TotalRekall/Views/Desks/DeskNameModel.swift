// DeskNameModel.swift
// One model per name-a-desk presentation (setup step, Save this desk? window, Rename). Save and
// cancel are idempotent so a button followed by the window's close path cannot fire twice.

import Foundation
import Observation

@MainActor
@Observable
final class DeskNameModel {
    enum Mode: Equatable, Sendable { case setup, newDesk, rename }

    let mode: Mode
    var text: String
    /// Names of every desk except the one being named.
    let otherNames: [String]
    private(set) var isFinished = false
    private let onSave: @MainActor (String) -> Void
    private let onCancel: @MainActor () -> Void

    init(mode: Mode,
         initialName: String,
         otherNames: [String],
         onSave: @escaping @MainActor (String) -> Void,
         onCancel: @escaping @MainActor () -> Void) {
        self.mode = mode
        self.text = initialName
        self.otherNames = otherNames
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var problem: DeskNameRules.Problem? { DeskNameRules.problem(for: text, otherNames: otherNames) }
    var message: String? { DeskNameRules.message(for: problem) }
    var canSave: Bool { problem == nil }

    /// Return / Save / Rename. Does nothing when the name is invalid or the model already finished.
    func save() {
        guard canSave, !isFinished else { return }
        isFinished = true
        onSave(DeskNameRules.normalized(text))
    }

    /// Esc / Not Now / Cancel / close button / Cmd-W.
    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        onCancel()
    }
}
