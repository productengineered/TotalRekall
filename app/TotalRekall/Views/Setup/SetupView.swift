// SetupView.swift
// The setup window content. Copy, states, AX identifiers and
// keyboard behaviour are unchanged from the state machine.

import AppKit
import SwiftUI

struct SetupView: View {
    let model: SetupViewModel
    /// Fixed content height (the tallest variant, so every state shares one window size). Nil lays out at the
    /// content's natural height, which is how the window measures each variant.
    var contentHeight: CGFloat?
    /// Renders this copy instead of the model's current state (used only to measure the other variants).
    var copyOverride: SetupCopy?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var copy: SetupCopy {
        copyOverride ?? SetupCopy(state: model.state, reason: model.reason, paneName: model.paneName)
    }

    var body: some View {
        let copy = copy
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
                .accessibilityIdentifier(AXID.Setup.title)

            Text(copy.body)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .accessibilityIdentifier(AXID.Setup.body)

            if let helper = copy.helper {
                helperRow(helper)
                    .padding(.top, 16)
                    .transition(.opacity)
            }

            // Header and body stay at the top; the button row is pinned to the bottom edge.
            Spacer(minLength: 24)

            HStack(spacing: 8) {
                buttons(copy)
            }
            .controlSize(.large)
        }
        .multilineTextAlignment(.center)
        .frame(width: 340)
        .padding(.top, 40)
        .padding(.horizontal, 40)
        .padding(.bottom, 28)
        .frame(width: SetupWindowController.contentWidth, height: contentHeight, alignment: .top)
        .fixedSize(horizontal: false, vertical: contentHeight == nil)
        .ignoresSafeArea(.container, edges: .top)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.state)
    }

    private func helperRow(_ helper: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            Text(helper)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(AXID.Setup.helper)
        }
    }

    @ViewBuilder
    private func buttons(_ copy: SetupCopy) -> some View {
        if let secondary = copy.secondary, let title = copy.secondaryTitle {
            secondaryButton(secondary, title: title)
        }
        // While waiting, "Open System Settings" is demoted to the secondary style (nothing to confirm yet).
        if copy.helper != nil {
            primaryButton(copy, prominent: false)
        } else {
            primaryButton(copy, prominent: true)
        }
    }

    @ViewBuilder
    private func primaryButton(_ copy: SetupCopy, prominent: Bool) -> some View {
        let button = Button(action: primaryAction(copy.primary)) {
            Text(copy.primaryTitle).frame(minWidth: 120)
        }
        .accessibilityHint(copy.primaryHint)
        .accessibilityIdentifier(AXID.Setup.primaryButton)
        if prominent {
            // Stays accent-blue when the window is inactive (see AlwaysActiveProminentButtonStyle).
            button.buttonStyle(AlwaysActiveProminentButtonStyle()).keyboardShortcut(.defaultAction)
        } else {
            button.buttonStyle(.glass)
        }
    }

    @ViewBuilder
    private func secondaryButton(_ secondary: SetupCopy.Secondary, title: String) -> some View {
        switch secondary {
        case .openSettings:
            Button(action: model.openSystemSettings) {
                Text(title).frame(minWidth: 120)
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier(AXID.Setup.secondaryButton)
        case .notNow:
            Button(action: model.skip) {
                Text(title).frame(minWidth: 120)
            }
            .buttonStyle(.glass)
            .keyboardShortcut(.cancelAction)
            .accessibilityHint("Closes this window. Total Rekall can't move windows until access is on.")
            .accessibilityIdentifier(AXID.Setup.skipButton)
        }
    }

    private func primaryAction(_ primary: SetupCopy.Primary) -> () -> Void {
        switch primary {
        case .openSettings: model.openSystemSettings
        case .relaunch: model.relaunch
        case .done: model.done
        }
    }
}

#if DEBUG
/// Previews render at the window's fixed (tallest-variant) height so shorter states show the pinned buttons.
private struct FixedHeightSetupPreview: View {
    let state: SetupState
    @State private var model: SetupViewModel
    @State private var height: CGFloat

    init(_ state: SetupState) {
        self.state = state
        let model = SetupViewModel.preview(state)
        _model = State(initialValue: model)
        _height = State(initialValue: SetupWindowController.fixedContentHeight(model: model))
    }

    var body: some View { SetupView(model: model, contentHeight: height) }
}

#Preview("First run · light") { FixedHeightSetupPreview(.needsPermission(.firstRun)) }
#Preview("First run · dark") { FixedHeightSetupPreview(.needsPermission(.firstRun)).preferredColorScheme(.dark) }
#Preview("Revoked · light") { FixedHeightSetupPreview(.needsPermission(.revoked)) }
#Preview("Revoked · dark") { FixedHeightSetupPreview(.needsPermission(.revoked)).preferredColorScheme(.dark) }
#Preview("Waiting · light") { FixedHeightSetupPreview(.waitingForGrant) }
#Preview("Waiting · dark") { FixedHeightSetupPreview(.waitingForGrant).preferredColorScheme(.dark) }
#Preview("Relaunch · light") { FixedHeightSetupPreview(.relaunchSuggested) }
#Preview("Relaunch · dark") { FixedHeightSetupPreview(.relaunchSuggested).preferredColorScheme(.dark) }
#Preview("Done · light") { FixedHeightSetupPreview(.granted) }
#Preview("Done · dark") { FixedHeightSetupPreview(.granted).preferredColorScheme(.dark) }
#endif
