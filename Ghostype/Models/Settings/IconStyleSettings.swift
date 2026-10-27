import Foundation

/// File overview:
/// The two icon choices in Settings > Appearance: what marks a field Ghostype is completing, and
/// what sits in the menu bar. Each is a plain string in `UserDefaults` so views bind with
/// `@AppStorage`. "None" is not stored here: it maps onto the existing switches
/// (`showIndicator`, `isMenuBarIconVisible`) so hiding keeps working exactly as before.

enum FieldIndicatorStyle: String, CaseIterable, Identifiable {
    case none
    /// Uncial "a" beside an I-beam (the original mark).
    case letterAndCursor
    case cursor
    case ghost

    static let defaultsKey = "ghostypeFieldIndicatorStyle"
    static let defaultStyle = FieldIndicatorStyle.letterAndCursor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .letterAndCursor: return "a + I"
        case .cursor: return "I"
        case .ghost: return "Ghost"
        }
    }

    /// The visible style; "none" is never stored (the show-indicator switch carries it).
    static func stored(_ raw: String) -> FieldIndicatorStyle {
        let style = FieldIndicatorStyle(rawValue: raw) ?? defaultStyle
        return style == .none ? defaultStyle : style
    }
}

enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    case none
    case ghost
    case pumpkin
    case winterGhost

    static let defaultsKey = "ghostypeMenuBarIconStyle"
    static let defaultStyle = MenuBarIconStyle.pumpkin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .ghost: return "Ghost"
        case .pumpkin: return "Pumpkin"
        case .winterGhost: return "Winter ghost"
        }
    }

    /// The visible style; "none" is never stored (the menu-bar-visible switch carries it).
    static func stored(_ raw: String) -> MenuBarIconStyle {
        let style = MenuBarIconStyle(rawValue: raw) ?? defaultStyle
        return style == .none ? defaultStyle : style
    }
}
