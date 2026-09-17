import KeepoCore
import SwiftUI

/// Title, body, content, bottom bar — the shape every setup step takes.
///
/// It exists so eight screens cannot drift. Left to themselves they would:
/// one would set `Spacing.xl` between its title and its field, the next
/// `Spacing.l`, and nobody would notice until all eight were seen in
/// sequence — which is the only way a user ever sees them. Screen edge is
/// `Spacing.l` and block separation `Spacing.xxl`, per the brand doc.
///
/// The content slot is deliberately unopinionated. A scaffold that also
/// tried to lay out its contents would be a second layout system competing
/// with SwiftUI's, and the eight steps hold genuinely different things — a
/// wheel, a grid, a form, a video.
struct OnboardingScaffold<Content: View>: View {
    let title: String
    /// One or two lines under the title. Optional because some steps say
    /// everything they need to in the title, and an empty subtitle that
    /// still reserves its space is the drift this type prevents.
    var subtitle: String?
    let step: SetupStep
    var onBack: (() -> Void)?
    var onSkip: (() -> Void)?
    /// Label and action for the forward button. Disabled when the step has
    /// something it genuinely still needs.
    var primaryTitle = "Next"
    var isPrimaryEnabled = true
    /// Hidden on the steps that own their own forward action: the account
    /// step's type choice (picking a card *is* the action), the category
    /// grid (whose Next scrolls with the content), and the capture intro
    /// (which offers two choices rather than one). A bar holding a
    /// permanently disabled button is worse than no bar — it reads as a
    /// control the user has somehow failed to satisfy.
    var isPrimaryVisible = true
    /// Puts the content **directly under the heading** instead of letting it
    /// float in the space below it.
    ///
    /// The default floats: the content sits between two flexible spacers, so
    /// a short block lands near the middle of the screen. That is right for
    /// a step holding one field or one wheel, and wrong for a step holding a
    /// list — the account type cards, the capture checklist — where floating
    /// opens a band of empty canvas under the subtitle and pushes the first
    /// item down for no reason the user can see.
    var pinsContentToTop = false
    /// The gap between the heading and the content. `xxl` is the brand's
    /// block separation and the right default; the steps that pin to the top
    /// generally want less, because the content is what the heading is
    /// introducing rather than a separate block.
    var contentGap = AppTheme.Spacing.xxl
    let onPrimary: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()

            VStack(spacing: 0) {
                OnboardingChrome(step: step, onBack: onBack, onSkip: onSkip)
                    .padding(.top, AppTheme.Spacing.s)

                // The heading stays at the top and the content floats in
                // whatever is left, rather than both stacking against the
                // top edge. The steps hold wildly different amounts — one
                // field on the first, a wheel on the second, a whole form
                // on the third — and top-stacking leaves the short ones
                // looking like a screen that failed to finish loading.
                // When the content is tall the two spacers collapse to
                // nothing and this is an ordinary scroll view again.
                GeometryReader { proxy in
                    ScrollView {
                        // **`spacing: 0`, with the gap carried by the top
                        // spacer's `minLength`.** A `VStack(spacing: xxl)`
                        // puts a gap on *both* sides of each spacer, so on a
                        // step whose content overflows — where the spacers
                        // collapse to zero height and should therefore
                        // disappear — the heading was still separated from
                        // the content by two gaps rather than one. Visible on
                        // the category grid and the dashboard as an
                        // unexplained band of empty canvas under the
                        // subtitle, and invisible in code because nothing
                        // there says 32 twice.
                        layout
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, AppTheme.Spacing.l)
                        .padding(.top, AppTheme.Spacing.xl)
                        .padding(.bottom, AppTheme.Spacing.xxl)
                        .frame(minHeight: proxy.size.height, alignment: .top)
                    }
                    // The content is short on most steps and long on two;
                    // this is the same rule `TransactionFormView` uses, so
                    // nothing rubber-bands until it genuinely overflows.
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollDismissesKeyboard(.interactively)
                }

                bottomBar
            }
        }
    }

    @ViewBuilder
    private var layout: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            // **A fixed gap, not a flexible one, when pinning.** Two
            // `Spacer`s share whatever slack is going equally, so a
            // `minLength` on the first one sets a floor and then grows past
            // it — which is exactly the floating behaviour being avoided.
            if pinsContentToTop {
                Spacer().frame(height: contentGap)
            } else {
                Spacer(minLength: contentGap)
            }
            content
            Spacer(minLength: 0)
        }
    }

    /// **Both lines are `fixedSize` vertically, and that is load-bearing.**
    /// The content below sits between two flexible spacers, so SwiftUI is
    /// free to negotiate this block's height — and given the chance it
    /// compresses the title to a single line and truncates it with an
    /// ellipsis rather than wrapping. It showed up as "Purchases, without
    /// o…" on the capture step the moment that step's subtitle got shorter,
    /// which is the worst shape of layout bug: invisible in code, and
    /// triggered by editing a different string.
    private var heading: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            Text(title)
                .font(AppTheme.Typography.screenTitle)
                .foregroundStyle(AppTheme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(AppTheme.Typography.body)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    // The token exists for exactly this: prose stops being
                    // readable past roughly this measure.
                    .frame(maxWidth: AppTheme.Size.proseWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// **Next, and nothing else.** This bar used to carry a second Back
    /// beside it, on the argument that the chevron is where a user expects
    /// the way back and the bottom-left is where their thumb already is.
    /// Both halves of that are true and it was still wrong: two controls
    /// performing the identical action on one screen read as two different
    /// actions, and on a six-screen flow the question "what does the other
    /// one do?" gets asked once and costs more than the reach ever saved.
    /// The chevron in `OnboardingChrome` is the only way back.
    @ViewBuilder
    private var bottomBar: some View {
        if isPrimaryVisible {
            HStack {
                Spacer(minLength: 0)
                OnboardingPrimaryButton(title: primaryTitle, isEnabled: isPrimaryEnabled, action: onPrimary)
            }
            .padding(.horizontal, AppTheme.Spacing.l)
            .padding(.top, AppTheme.Spacing.m)
            .padding(.bottom, AppTheme.Spacing.s)
        }
    }
}

/// The one forward action on a setup step — and on sign-in, which is the
/// same button doing the same job at the same point in the same flow.
///
/// **Disabled is a neutral fill, not a faded accent.** A dimmed amber still
/// reads as a coloured button with white text on it — as a live control
/// someone will tap and be confused by — so the disabled state drops the
/// accent entirely and takes `textSecondary` with it. The difference has to
/// be a difference in *kind*, because "not yet" is what it means.
struct OnboardingPrimaryButton: View {
    let title: String
    var isEnabled = true
    /// Swaps the label for a spinner while a network call is in flight,
    /// keeping the button's own size so nothing reflows around it.
    var isLoading = false
    /// Sign-in's button spans the field above it; a setup step's hugs its
    /// label in the bottom bar.
    var fillsWidth = false
    let action: () -> Void

    private var isActive: Bool { isEnabled && !isLoading }

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, fillsWidth ? 0 : AppTheme.Spacing.xl)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .frame(height: AppTheme.Size.touchTarget)
                .background(
                    isActive ? AppTheme.Palette.brandPrimary : AppTheme.Palette.fillStrong,
                    in: Capsule()
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.pressableCard)
        .disabled(!isActive)
        .animation(AppTheme.Motion.colorSafe, value: isActive)
        .sensoryFeedback(AppTheme.Feedback.buttonPress, trigger: title)
    }

    @ViewBuilder
    private var label: some View {
        if isLoading {
            ProgressView().tint(AppTheme.Palette.textSecondary)
        } else {
            Text(title)
                .font(AppTheme.Typography.labelEmphasis)
                .foregroundStyle(isActive ? AppTheme.Palette.textOnAccent : AppTheme.Palette.textSecondary)
        }
    }
}

/// Back. Quiet on purpose — it is an escape hatch, not a second choice
/// competing with the one the screen is asking for — but **outlined**, so
/// it still reads as a control. Bare text on the canvas, with no fill and
/// no border, read as a label that happened to be tappable.
///
/// The outline rather than a fill is what keeps the hierarchy: same
/// capsule and same height as the primary beside it, so the pair looks
/// deliberate, with the weight carried entirely by the primary's fill.
struct OnboardingSecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AppTheme.Typography.label)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .padding(.horizontal, AppTheme.Spacing.l)
                .frame(height: AppTheme.Size.touchTarget)
                .overlay(Capsule().stroke(AppTheme.Palette.textSecondary, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
