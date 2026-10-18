import SwiftUI

// PanelButton and PanelCard are ported from LGwebOS-menubar's RemoteView.swift (MIT).
struct PanelButton: ButtonStyle {
    var selected = false
    var accent: Color = Theme.neutralAccent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? accent : Theme.buttonInk)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous)
                .fill(selected ? accent.opacity(0.19) : configuration.isPressed ? Theme.buttonPressedFill : Theme.buttonFill))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

struct PanelCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: Theme.borderWidth))
    }
}
