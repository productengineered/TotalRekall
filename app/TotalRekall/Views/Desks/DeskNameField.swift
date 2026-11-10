// DeskNameField.swift
// The name field and its one-line validation message, shared by the setup step, the new-desk prompt
// and Rename. The message line always occupies a line so it never changes a window's size.

import SwiftUI

struct DeskNameField: View {
    @Bindable var model: DeskNameModel
    let fieldID: String
    let messageID: String
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6) {
            TextField("Desk name", text: $model.text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($focused)
                .onSubmit { model.save() }
                .onChange(of: model.text) { _, newValue in
                    let clamped = DeskNameRules.clamped(newValue)
                    if clamped != newValue { model.text = clamped }
                }
                .accessibilityLabel("Desk name")
                .accessibilityHint("Type a name for this desk. Press Return to save.")
                .accessibilityIdentifier(fieldID)

            Text(model.message ?? " ")
                .font(.callout)
                .foregroundStyle(.secondary)
                .opacity(model.message == nil ? 0 : 1)
                .accessibilityHidden(model.message == nil)
                .accessibilityIdentifier(messageID)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.message)
        }
        .task { focused = true }
        .onChange(of: model.message) { _, newValue in
            if let newValue { AccessibilityNotification.Announcement(newValue).post() }
        }
    }
}
