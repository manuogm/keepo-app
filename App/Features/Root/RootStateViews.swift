import SwiftUI

/// Small, stateless views for `RootView`'s launch/error/privacy-curtain
/// states — kept together since none of them are reusable outside the
/// root router, unlike `Common/Components`.
/// The launch splash: what the app draws while the session is being
/// restored — and, deliberately, **what the launch screen already showed**.
///
/// Same teal ground, same white K, in the same place, so the handoff from
/// the OS's static launch image to the first SwiftUI frame is invisible.
/// The quote and the spinner are the only things that arrive, because text
/// and motion are what a launch screen cannot have: `UILaunchScreen` is a
/// background colour and one image, with no code behind it.
///
/// `RootView` holds it on screen for at least `minimumDwell` on a cold
/// launch, so the quote can actually be read — see `RootView.isSplashHeld`.
struct RootLoadingView: View {
    /// How long the mark sits alone before the quote begins to ease in —
    /// the beat that makes the launch read as mark first, then words,
    /// rather than one screen arriving all at once.
    private static let quoteDelay: Duration = .milliseconds(500)

    /// How long the quote stays fully visible before the splash may leave.
    private static let readingTime: Duration = .milliseconds(2500)

    /// The shortest a cold launch keeps the splash up, counted so the
    /// quote gets all of `readingTime` *after* it has finished arriving. A
    /// returning user's session restores from the local mirror almost
    /// instantly, so without a floor the quote would never be read.
    static let minimumDwell = quoteDelay + .seconds(AppTheme.Motion.revealDuration) + readingTime

    /// Matches the rendition in `LaunchMark.imageset`, which is drawn at
    /// its natural size by the launch screen. Change one and change the
    /// other, or the mark resizes at the handoff.
    private static let markHeight = AppTheme.Size.illustration

    private let quote = LaunchQuote.forThisLaunch
    @State private var isQuoteShown = false

    var body: some View {
        // The mark is centred **on its own**, not inside a stack with
        // the spinner, and **in the whole screen**, not the safe area:
        // that is where `UILaunchScreen` centres its image
        // (`UIImageRespectsSafeAreaInsets` is false). Centred in the safe
        // area instead, the mark sat half the difference between the top
        // and bottom insets lower than the launch screen's, and visibly
        // jumped the instant the app took over — the one seam this view
        // exists to remove.
        ZStack {
            AppTheme.Palette.launchBackground
            Image("LaunchMark")
                .resizable()
                .scaledToFit()
                .frame(height: Self.markHeight)
            ProgressView()
                .tint(AppTheme.Palette.textOnAccent)
                .offset(y: Self.markHeight / 2 + AppTheme.Spacing.xl)
            // Centred in the screen's lower half: clear of the spinner
            // above and the home indicator below on every screen
            // height, and close enough to the mark to read as part of
            // the same moment rather than as a footnote.
            VStack(spacing: 0) {
                Color.clear
                quoteView
                    .frame(maxHeight: .infinity)
                    .opacity(isQuoteShown ? 1 : 0)
            }
        }
        .ignoresSafeArea()
        // Eased in after a beat rather than present on the first frame:
        // the launch screen had no quote, so one that is simply *there*
        // reads as a jump at the handoff.
        .task {
            try? await Task.sleep(for: Self.quoteDelay)
            guard !Task.isCancelled else { return }
            withAnimation(AppTheme.Motion.reveal) { isQuoteShown = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// Quiet on purpose — a step under body size and no wider than a
    /// popover's prose, so the mark stays the subject. The author steps
    /// down again and goes italic, a signature under the line rather than
    /// a second line of it.
    private var quoteView: some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            // Typographic quotes, not straight `"` — the curly pair is what
            // a printed quotation uses, and the straight mark reads as code.
            // Only on screen: VoiceOver gets the bare words (see
            // `accessibilityText`), since it reads quote marks aloud.
            Text("\u{201C}\(quote.text)\u{201D}")
                .font(AppTheme.Typography.label)
            Text(quote.author)
                .font(AppTheme.Typography.micro)
                .italic()
        }
        .foregroundStyle(AppTheme.Palette.textOnAccent)
        .multilineTextAlignment(.center)
        .frame(maxWidth: AppTheme.Size.proseWidth)
    }

    private var accessibilityText: String {
        "Keepo is starting. \(quote.text) — \(quote.author)"
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
