// AlwaysActiveProminentButtonStyle.swift
// The setup window's primary call to action.
//
// DELIBERATE, USER-REQUESTED DEVIATION from the macOS inactive-window dimming convention: the system
// `.glassProminent` style greys out whenever its window is not key, which happens every time System Settings comes
// forward during setup. People read grey as "not clickable" and clicked the window first. This style draws the accent
// fill and white label regardless of window active state, so the one thing to click stays obviously clickable.
// Use it only for that purpose; everything else keeps the standard look.
//
// Why not `.environment(\.controlActiveState, .key)` on the system style: glass materials do not render outside a
// live window, so an inactive appearance can't be demonstrated without taking over the screen, and the override is an
// unsupported way of steering the style. This style's fill is plain SwiftUI and renders everywhere.

import SwiftUI

struct AlwaysActiveProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    /// Fill colour. Defaults to the accent; the Forget Desk confirmation passes `.red` for its destructive button.
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, verticalPadding)
            .background(fill(pressed: pressed), in: Capsule())
            .overlay {
                if !reduceTransparency {
                    // Soft top highlight keeps it close to Tahoe's glass prominent button.
                    Capsule().fill(LinearGradient(colors: [.white.opacity(0.22), .clear],
                                                  startPoint: .top, endPoint: .center))
                }
            }
            .overlay {
                if contrast == .increased {
                    Capsule().strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
                }
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pressed)
            .onHover { isHovering = $0 }
    }

    private var verticalPadding: CGFloat {
        switch controlSize {
        case .mini, .small: 3
        case .large, .extraLarge: 9
        default: 6
        }
    }

    private func fill(pressed: Bool) -> Color {
        let base = tint
        if pressed { return base.mix(with: .black, by: contrast == .increased ? 0.35 : 0.22) }
        if isHovering { return base.mix(with: .white, by: 0.12) }
        return contrast == .increased ? base.mix(with: .black, by: 0.2) : base
    }
}
