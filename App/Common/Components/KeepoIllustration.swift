import SwiftUI

/// A line drawing from `Assets.xcassets/Illustrations`, fitted to a square box.
///
/// The counterpart of `KeepoIcon` for artwork that carries its own ink:
/// these are **not** template images, so `foregroundStyle` does nothing to
/// them. Each asset ships a transparent background and a dark-appearance
/// variant, so the art sits on the canvas in both schemes instead of
/// arriving as a white rectangle. Decorative — the caption beside it says
/// what the screen is — so VoiceOver skips it.
struct KeepoIllustration: View {
    let name: String
    var size: CGFloat = AppTheme.Size.illustrationHero

    var body: some View {
        Image(name)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
