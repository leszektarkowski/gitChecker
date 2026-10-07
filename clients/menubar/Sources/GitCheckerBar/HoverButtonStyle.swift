import SwiftUI

extension Color {
    /// Shared hover highlight for repo rows and text buttons.
    static let hoverHighlight = Color.secondary.opacity(0.15)
    static let pressedHighlight = Color.secondary.opacity(0.28)
}

/// A text button that looks and behaves like one: a rounded highlight on hover
/// (the same as the repo rows), a darker one while pressed, and dimmed text
/// when disabled. Replaces `.borderless`, which gives no hover feedback.
struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverButton(configuration: configuration)
    }

    private struct HoverButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .background(RoundedRectangle(cornerRadius: 6).fill(highlight))
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onHover { hovering = $0 }
        }

        private var highlight: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed { return .pressedHighlight }
            return hovering ? .hoverHighlight : .clear
        }
    }
}

extension ButtonStyle where Self == HoverButtonStyle {
    static var hover: HoverButtonStyle { HoverButtonStyle() }
}
