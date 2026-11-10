// ForgetDeskView.swift
// The Forget Desk confirmation's content, in the same opaque style as DeskNameView and SetupView:
// icon, title, body, then Cancel (default) and Forget Desk (destructive, red).

import SwiftUI

struct ForgetDeskView: View {
    @Bindable var model: ForgetDeskModel
    /// Fixed content height, measured once per show. Nil lays out at natural height (used only to measure).
    var contentHeight: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            Image("SetupBear")
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)

            Text(model.title)
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(AXID.Desk.title)

            Text(model.body)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .accessibilityIdentifier(AXID.Desk.body)

            Spacer(minLength: 24)

            HStack(spacing: 8) {
                Button(action: model.cancel) {
                    Text("Cancel").frame(minWidth: 120)
                }
                .buttonStyle(.glass)
                .keyboardShortcut(.defaultAction)   // Cancel is the default: Return cancels
                .accessibilityHint("Closes this window and keeps the desk")
                .accessibilityIdentifier(AXID.Desk.forgetCancelButton)

                Button(action: model.forget) {
                    Text("Forget Desk").frame(minWidth: 120)
                }
                .buttonStyle(AlwaysActiveProminentButtonStyle(tint: .red))
                .accessibilityHint("Removes this desk. You will be asked to name it again when you reconnect.")
                .accessibilityIdentifier(AXID.Desk.forgetConfirmButton)
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
#Preview("Forget Desk · light") {
    ForgetDeskView(model: ForgetDeskModel(deskName: "Home Docking Station", onForget: {}))
}
#Preview("Forget Desk · dark") {
    ForgetDeskView(model: ForgetDeskModel(deskName: "Home Docking Station", onForget: {}))
        .preferredColorScheme(.dark)
}
#endif
