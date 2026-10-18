import SwiftUI

// Cross-platform wrappers for iOS-specific navigation modifiers.
// On macOS these are no-ops so the app compiles without Catalyst-specific guards
// scattered throughout every view.

extension View {
    @ViewBuilder
    func hhNavTitleStyle(_ mode: HHNavTitleStyle) -> some View {
        #if os(iOS)
        switch mode {
        case .large:  self.navigationBarTitleDisplayMode(.large)
        case .inline: self.navigationBarTitleDisplayMode(.inline)
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func hhHideNavigationBar() -> some View {
        #if os(iOS)
        self.toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }
}

enum HHNavTitleStyle {
    case large, inline
}
