import SwiftUI

/// Small, stateless views for `RootView`'s launch/error/privacy-curtain
/// states — kept together since none of them are reusable outside the
/// root router, unlike `Common/Components`.
/// What the app draws while the session is being restored — and,
/// deliberately, **what the launch screen already showed**.
///
/// Same canvas, same mark, in the same place, so the handoff from the OS's
/// static launch image to the first SwiftUI frame is invisible. The spinner
/// is the only thing that arrives, because it is the only thing a launch
/// screen cannot have: `UILaunchScreen` is a background colour and one
/// image, with no code behind it.
///
/// It used to draw the word "Keepo" instead, which could never match —
/// a launch screen cannot render text.
struct RootLoadingView: View {
    /// Matches the rendition in `LaunchMark.imageset`, which is drawn at
    /// its natural size by the launch screen. Change one and change the
    /// other, or the mark resizes at the handoff.
    private static let markHeight = AppTheme.Size.illustration + AppTheme.Spacing.xl

    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()
            // The mark is centred **on its own**, not inside a stack with
            // the spinner: `UILaunchScreen` centres its image in the whole
            // screen, so a `VStack` here would centre the pair instead and
            // the mark would hop upward the instant the app took over — the
            // one visible seam this is all meant to remove.
            Image("LaunchMark")
                .resizable()
                .scaledToFit()
                .frame(height: Self.markHeight)
            ProgressView()
                .offset(y: Self.markHeight / 2 + AppTheme.Spacing.xl)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Keepo is starting")
    }
}

struct RootPrivacyCurtainView: View {
    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()
            Text("Keepo")
                .font(AppTheme.Typography.sectionTitle).fontWeight(.bold)
                .foregroundStyle(AppTheme.Palette.textPrimary)
        }
    }
}

struct RootErrorView: View {
    let message: String

    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()
            VStack(spacing: AppTheme.Spacing.m) {
                Text("Couldn't connect")
                    .font(AppTheme.Typography.sectionTitle).fontWeight(.bold)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                Text(message)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
    }
}
