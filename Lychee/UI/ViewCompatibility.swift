import SwiftUI

extension View {
    @ViewBuilder
    func lycheeFocusEffectDisabled() -> some View {
        if #available(macOS 14.0, *) {
            self.focusEffectDisabled()
        } else {
            self
        }
    }
}
