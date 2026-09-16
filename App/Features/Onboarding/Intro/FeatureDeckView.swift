import KeepoCore
import SwiftUI

/// The four things Keepo is, as a deck you can flick through.
///
/// **A paged deck rather than four pushes** (§3.1). Four separate screens
/// make a user who has understood the pitch tap four times to get past it,
/// and give a user who wants to re-read one no way back. A deck does both,
/// and the gesture is already established in the app by the scope banner's
/// carousel.
///
/// **One button, and it is the way out rather than the way through**
/// (user's call, 2026-09-16). It stays disabled until all four slides have
/// actually been seen, so the deck cannot be dismissed off the first
/// screen — swiping is how you move, which is what the page dots have been
/// saying all along. Its label is the destination the whole time, so the
/// user can see where the deck ends before they get there.
///
/// That also settles §3.2: "Great start, what is next?" / "Wow, show me
/// more!" put words in the user's mouth and were the longest strings on
/// their own screens, in an app whose voice everywhere else is dry. With
/// one button there is one string, and it is the only personality moment —
/// which lands, because by the time it lights up the user has read the
/// whole pitch.
struct FeatureDeckView: View {
    let onFinished: () -> Void

    @State private var index = 0
    /// Which slides have actually been on screen. A `Set` rather than a
    /// high-water mark: swiping back and forth must not un-see anything,
    /// and the user is free to arrive at four by any route they like.
    @State private var seen: Set<Int> = [0]

    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()

            VStack(spacing: AppTheme.Spacing.xl) {
                TabView(selection: $index) {
                    ForEach(Array(FeatureSlide.all.enumerated()), id: \.element.id) { position, slide in
                        FeatureSlideView(slide: slide)
                            .tag(position)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                PageDots(count: FeatureSlide.all.count, index: index)

                OnboardingPrimaryButton(
                    title: "I'm in. Take me to Keepo", isEnabled: hasSeenEverything, action: onFinished
                )
            }
            .padding(.horizontal, AppTheme.Spacing.l)
            .padding(.vertical, AppTheme.Spacing.xxl)
        }
        .sensoryFeedback(AppTheme.Feedback.selection, trigger: index)
        .onChange(of: index) { _, current in seen.insert(current) }
    }

    private var hasSeenEverything: Bool { seen.count == FeatureSlide.all.count }
}

/// One feature: a mark, a claim, and at most three lines saying why it is
/// true. Nothing here is a paragraph — a user reading four of these in
/// sequence reads none of them if any one is dense.
private struct FeatureSlideView: View {
    let slide: FeatureSlide

    var body: some View {
        VStack(spacing: AppTheme.Spacing.xl) {
            Spacer(minLength: 0)

            KeepoIcon(name: slide.icon, size: AppTheme.Size.illustration)
                .foregroundStyle(AppTheme.Palette.brandPrimary)

            VStack(spacing: AppTheme.Spacing.m) {
                Text(slide.title)
                    .font(AppTheme.Typography.screenTitle)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                    .multilineTextAlignment(.center)

                VStack(spacing: AppTheme.Spacing.s) {
                    ForEach(slide.lines, id: \.self) { line in
                        Text(line)
                            .font(AppTheme.Typography.body)
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: AppTheme.Size.proseWidth)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Where you are in the deck. Same vocabulary as the setup flow's own
/// progress dots — current one a pill — so the two halves of onboarding do
/// not each invent their own way of saying "four of these, this one".
private struct PageDots: View {
    let count: Int
    let index: Int

    private static let pillWidth: CGFloat = 20

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            ForEach(0..<count, id: \.self) { dot in
                Capsule()
                    .fill(dot == index ? AppTheme.Palette.brandPrimary : AppTheme.Palette.fillStrong)
                    .frame(width: dot == index ? Self.pillWidth : AppTheme.Size.dot, height: AppTheme.Size.dot)
            }
        }
        .animation(AppTheme.Motion.quick, value: index)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(index + 1) of \(count)")
    }
}

struct FeatureSlide: Identifiable, Equatable {
    let id: String
    let icon: String
    let title: String
    let lines: [String]

    /// Copy is settled in the plan's §3.3 and §3.4 — the two claims that
    /// needed changing rather than polishing.
    static let all: [FeatureSlide] = [
        FeatureSlide(
            id: "privacy",
            icon: "icon-lock",
            title: "Privacy first",
            // Three checkable facts instead of one unfalsifiable "it's all
            // yours" (§3.4). The general claim invites a fair "then why is
            // it on a server?"; these three survive the question, and they
            // are the more convincing answer anyway.
            lines: [
                "No bank logins. Keepo never connects to your bank.",
                "Your data is never sold, and never used to train AI.",
                "Encrypted in transit and at rest, readable only by you."
            ]
        ),
        FeatureSlide(
            id: "capture",
            icon: "icon-tap",
            title: "Automatic capturing",
            // "Set up Keepo to detect…" rather than "Keepo detects…"
            // (§3.3). Keepo detects nothing on its own — iOS Shortcuts
            // does, for the cards you pick, on this device. Promising
            // automatic here and handing over a Shortcuts walkthrough ten
            // screens later is exactly the experience the welcome screen
            // opens by condemning.
            lines: [
                "Logging every transaction by hand is a pain.",
                "Set up Keepo to detect each tap-payment you make and log it for you.",
                "Pick the account or fix the category straight from the notification."
            ]
        ),
        FeatureSlide(
            id: "yours",
            icon: "icon-slider",
            title: "Build it your way",
            lines: [
                "Your accounts, your categories, your dashboard.",
                "Put the numbers you care about first, and leave out the ones you don't.",
                "Nothing here is a template you have to live with."
            ]
        ),
        FeatureSlide(
            id: "household",
            icon: "icon-shared",
            title: "Share your finances",
            lines: [
                "Share the accounts you hold together, and keep everything else private.",
                "Both of you see the shared money. Neither of you sees the rest.",
                "Set it up standing next to each other, in about a minute."
            ]
        )
    ]
}

#Preview {
    FeatureDeckView {}
}
