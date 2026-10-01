import SwiftUI

extension View {
    /// iOS 26's Liquid Glass where it exists, the older material blur
    /// where it doesn't — the deployment target is still 18.0. Both draw
    /// their own edge, so nothing here adds a border of its own.
    ///
    /// Shared by the tab bar and by the controls that float over content
    /// without a toolbar to put them in — the widget catalogue's close
    /// button, which has to look like every sheet's toolbar X.
    @ViewBuilder
    func liquidGlass(in shape: some Shape) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(AppTheme.Palette.textPrimary.opacity(0.06), lineWidth: 0.5))
        }
    }
}
