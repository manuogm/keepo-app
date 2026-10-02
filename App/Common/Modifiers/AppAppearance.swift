import SwiftUI

/// Applies the user's Dark Mode choice — the app's **only** way of writing
/// `.preferredColorScheme`.
///
/// **Optional, never resolved.** `.system` passes `nil`, the one value that
/// leaves iOS in charge. Nothing may resolve it to a concrete scheme,
/// because `.preferredColorScheme` is a *preference* — it travels up to the
/// window, including out of a sheet's content — so a descendant that pins
/// `light`/`dark` also pins the window, and a view reading
/// `@Environment(\.colorScheme)` to *decide* the override is then reading
/// back its own output. That loop is what once stopped the app following a
/// live system flip.
///
/// **Applied at the root and again on the Profile sheet.** The root's
/// preference retints the window, but a sheet already on screen keeps the
/// scheme it was presented with: its content lives in its own hosting
/// controller, which the root's change does not reach. Profile is where
/// the toggle lives, so it is exactly the sheet that is open when the
/// setting changes — reasserting the same stored value on it is what lets
/// it repaint without being closed and reopened. Both call sites read the
/// same `@AppStorage` key, so they can never disagree.
private struct AppAppearance: ViewModifier {
    @AppStorage(AppSettingsKeys.appearanceMode) private var appearanceMode = AppearanceMode.system

    func body(content: Content) -> some View {
        content.preferredColorScheme(appearanceMode.colorScheme)
    }
}

extension View {
    func appAppearance() -> some View {
        modifier(AppAppearance())
    }
}
