import SwiftUI

// Every color and dimension used by the panel. Values for the shell come from
// LGwebOS-menubar (MIT); see THIRD_PARTY_NOTICES.md.
enum Theme {
    // Panel geometry
    static let panelWidth: CGFloat = 360
    static let cornerRadius: CGFloat = 18
    static let arrowWidth: CGFloat = 24
    static let arrowHeight: CGFloat = 11
    static let horizontalPadding: CGFloat = 13
    static let minimumPanelHeight: CGFloat = 300

    // Surfaces
    static let backgroundTop = Color(red: 0.065, green: 0.070, blue: 0.080)
    static let backgroundBottom = Color(white: 0.042)
    static var background: LinearGradient {
        LinearGradient(colors: [backgroundTop, backgroundBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static let arrowFill = Color(red: 0.085, green: 0.095, blue: 0.10)
    static let borderOpacity = 0.13
    static let borderWidth: CGFloat = 0.7

    // Ink
    static let ink = Color.white.opacity(0.86)
    static let buttonInk = Color.white.opacity(0.79)
    static let mutedInk = Color.white.opacity(0.49)
    static let faintInk = Color.white.opacity(0.27)

    // Cards, buttons and the tab bar
    static let cardRadius: CGFloat = 12
    static let cardFill = Color.white.opacity(0.068)
    static let cardBorder = Color.white.opacity(0.085)
    static let buttonRadius: CGFloat = 9
    static let buttonFill = Color.white.opacity(0.065)
    static let buttonPressedFill = Color.white.opacity(0.13)
    static let tabBarFill = Color.white.opacity(0.066)
    static let tabBarBorder = Color.white.opacity(0.08)

    // Status
    static let warning = Color.orange
    static let online = Color.green

    // Accent shown when no mode is known (signed out, unit off).
    static let neutralAccent = Color(red: 0.62, green: 0.66, blue: 0.70)

    static func accent(for mode: ACMode?) -> Color {
        switch mode {
        case .cool: return Color(red: 0.25, green: 0.62, blue: 1.00)
        case .heat: return Color(red: 1.00, green: 0.55, blue: 0.20)
        case .dry: return Color(red: 0.18, green: 0.78, blue: 0.74)
        case .fan: return Color(red: 0.66, green: 0.68, blue: 0.71)
        case .auto: return Color(red: 0.35, green: 0.82, blue: 0.45)
        case nil: return neutralAccent
        }
    }
}
