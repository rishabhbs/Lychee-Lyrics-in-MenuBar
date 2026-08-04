import SwiftUI
import AppKit

extension TrackState.PopoverTheme {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark:   return .dark
        case .light:  return .light
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .dark:   return NSAppearance(named: .darkAqua)
        case .light:  return NSAppearance(named: .aqua)
        }
    }
}

private struct LycheeWindowThemeModifier: ViewModifier {
    @ObservedObject private var trackState = TrackState.shared

    func body(content: Content) -> some View {
        content.preferredColorScheme(trackState.popoverTheme.colorScheme)
    }
}

extension View {
    func lycheeWindowTheme() -> some View {
        modifier(LycheeWindowThemeModifier())
    }
}
