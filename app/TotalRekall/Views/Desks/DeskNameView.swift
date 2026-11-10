// DeskNameView.swift
// The "Save this desk?" window's content and the Rename window's content (one view, two copies).
// Style source: SetupView. The message line always reserves its height, so nothing resizes.

import SwiftUI

/// Copy per mode (named-desks-spec, Copy table).
struct DeskNameCopy: Equatable, Sendable {
    let title: String
    let body: String
    let confirmTitle: String
    let confirmHint: String
    let cancelTitle: String
    let cancelHint: String
    let windowTitle: String

    init(mode: DeskNameModel.Mode) {
        switch mode {
        case .rename:
            title = "Rename this desk"
            body = "Pick a name that's easy to spot in the Desks menu."
            confirmTitle = "Rename"
            confirmHint = "Renames this desk"
            cancelTitle = "Cancel"
            cancelHint = "Closes this window without changing the name"
            windowTitle = "Rename Desk"
        case .newDesk, .setup:
            title = "Save this desk?"
            body = "These monitors are new to TotalRekall. Check that they're arranged the way you like them, then save."
            confirmTitle = "Save"
            confirmHint = "Saves the desk name and the way your monitors are arranged"
            cancelTitle = "Not Now"
            cancelHint = "Closes this window. The desk keeps its current name and you can rename it from the Desks menu."
            windowTitle = "Save This Desk"
        }
    }
}

struct DeskNameView: View {
    @Bindable var model: DeskNameModel
    /// Fixed content height, measured once per show. Nil lays out at natural height (used only to measure).
    var contentHeight: CGFloat?

    var body: some View {
        let copy = DeskNameCopy(mode: model.mode)
        VStack(spacing: 0) {
            Image("SetupBear")
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)

            Text(copy.title)
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(AXID.Desk.title)

            Text(copy.body)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .accessibilityIdentifier(AXID.Desk.body)

            DeskNameField(model: model, fieldID: AXID.Desk.nameField, messageID: AXID.Desk.message)
                .padding(.top, 16)

            // Header, body and field stay at the top; the button row is pinned to the bottom edge.
            Spacer(minLength: 24)

            HStack(spacing: 8) {
                Button(action: model.cancel) {
                    Text(copy.cancelTitle).frame(minWidth: 120)
                }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
                .accessibilityHint(copy.cancelHint)
                .accessibilityIdentifier(AXID.Desk.cancelButton)

                Button(action: model.save) {
                    Text(copy.confirmTitle).frame(minWidth: 120)
                }
                .buttonStyle(AlwaysActiveProminentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
                .accessibilityHint(copy.confirmHint)
                .accessibilityIdentifier(AXID.Desk.confirmButton)
            }
            .controlSize(.large)
        }
        .multilineTextAlignment(.center)
        .frame(width: 340)
        .padding(.top, 40)
        .padding(.horizontal, 40)
        .padding(.bottom, 28)
        .frame(width: DeskNameWindowController.contentWidth, height: contentHeight, alignment: .top)
        .fixedSize(horizontal: false, vertical: contentHeight == nil)
        .ignoresSafeArea(.container, edges: .top)
    }
}

#if DEBUG
@MainActor
private func previewModel(_ mode: DeskNameModel.Mode, name: String) -> DeskNameModel {
    DeskNameModel(mode: mode, initialName: name, otherNames: ["Studio"], onSave: { _ in }, onCancel: {})
}

#Preview("Save this desk? · light") { DeskNameView(model: previewModel(.newDesk, name: "Desk 2")) }
#Preview("Save this desk? · dark") {
    DeskNameView(model: previewModel(.newDesk, name: "Desk 2")).preferredColorScheme(.dark)
}
#Preview("Rename · light") { DeskNameView(model: previewModel(.rename, name: "Desk 2")) }
#endif
