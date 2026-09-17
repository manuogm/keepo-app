import KeepoCore
import SwiftUI
import UIKit
import UserNotifications

/// Step 4a — why notifications, then an explicit ask.
///
/// **The explanation is not marketing, it is the feature's actual shape.**
/// A captured purchase never opens Keepo: the notification *is* the review
/// surface, carrying the amount, the category and quick actions to confirm
/// or fix it without launching anything. Without permission, capture still
/// works and the user simply never finds out a purchase was recorded until
/// they open the app — which is a materially worse product, and worth one
/// screen to say so.
///
/// The ask goes through `NotificationPermission`, the one place in the app
/// that calls `requestAuthorization` — iOS answers once, ever, so a second
/// call site is a call that looks like it did something and did not.
struct SetupNotificationsSubStep: View {
    let store: OnboardingDraftStore
    let onNext: () -> Void
    let onBack: () -> Void

    @State private var status: UNAuthorizationStatus = .notDetermined
    @State private var isAsking = false

    var body: some View {
        OnboardingScaffold(
            title: "Stay on top of your spending",
            subtitle: "A captured purchase arrives as a notification you can confirm or fix "
                + "without opening the app.",
            step: .capture,
            onBack: onBack,
            // **No Skip, and no second button.** This screen used to carry
            // "Turn on notifications" in the content *and* Next in the bar
            // *and* Skip in the chrome — three controls for one decision,
            // two of which did the same thing. Next is now the ask: it
            // raises the system prompt and moves on whatever the answer is,
            // so the screen has exactly one forward action and declining
            // costs nobody an extra tap.
            isPrimaryEnabled: !isAsking,
            onPrimary: askThenAdvance,
            content: {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
                    NotificationShowcase(currency: store.draft.baseCurrency)
                    deniedNote
                }
            }
        )
        .task {
            status = await NotificationPermission.status()
        }
    }

    /// The one state no app can fix from the inside, and the only one that
    /// still needs words on this screen.
    @ViewBuilder
    private var deniedNote: some View {
        switch status {
        case .denied:
            // The one state no app can fix from the inside: once "Don't
            // Allow" has been answered, `requestAuthorization` silently
            // replays it forever. So this offers the only thing that works
            // — a direct jump to Keepo's own Settings page — instead of a
            // button that would do nothing.
            VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
                Text("Notifications are turned off for Keepo.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .font(AppTheme.Typography.labelEmphasis)
                .foregroundStyle(AppTheme.Palette.brandPrimary)
            }
        case .authorized, .provisional, .ephemeral:
            Label("Notifications are on", systemImage: "checkmark.circle.fill")
                .font(AppTheme.Typography.labelEmphasis)
                .foregroundStyle(AppTheme.Palette.statusPositive)
        default:
            // `.notDetermined` — nothing has been asked yet, and a line
            // saying so would be narrating the absence of an event.
            EmptyView()
        }
    }

    /// Ask, then move on **whatever the answer was**.
    ///
    /// The permission is not a gate: Keepo works without notifications, the
    /// capture still lands, and Needs Review still shows it. So a decline
    /// must not strand anyone on this screen, and the advance is sequenced
    /// after the prompt rather than behind a second tap on it.
    ///
    /// `requestIfNeeded` returns immediately when the answer already exists
    /// — iOS replays a previous "Don't Allow" silently and forever — so
    /// coming back to this screen is Next behaving like Next.
    private func askThenAdvance() {
        Task { await requestThenAdvance() }
    }

    private func requestThenAdvance() async {
        isAsking = true
        status = await NotificationPermission.requestIfNeeded()
        store.update { $0.notificationAsked = true }
        isAsking = false
        onNext()
    }
}

/// What a capture actually looks like — four honest stills, swipeable,
/// each already long-pressed.
///
/// **One card was a half-truth.** The screen asks for permission to send
/// notifications and showed a single happy-path capture: everything
/// resolved, nothing to do. That is the least interesting of the four and
/// the one that least needs a notification. The ones that earn the
/// permission are the others — a category Keepo had to guess, a card it has
/// never seen, and a purchase that looks like it already happened — and
/// each of those turns into a row of buttons that settles it without
/// opening the app. A user who has seen those four knows what they are
/// agreeing to.
///
/// **Shown expanded, because that is where the buttons are.** The
/// notification body says "Press for quick actions" and the card underneath
/// it used to show none, which asks the reader to imagine the feature. The
/// actions are the feature.
///
/// Nothing here is hand-written: the text comes from
/// `CaptureNotificationCopy.appliedLocally` and the buttons from
/// `CaptureQuickActions.build`, both fed the resolutions in
/// `CaptureNotificationCopy.showcase`. A card cannot promise a shape
/// production does not send.
private struct NotificationShowcase: View {
    let currency: String?

    @State private var visible: Int?

    private var samples: [CaptureLocalWrite.Resolution] {
        CaptureNotificationCopy.showcase(currency: currency)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: AppTheme.Spacing.m) {
                    ForEach(Array(samples.enumerated()), id: \.offset) { index, resolution in
                        NotificationStill(resolution: resolution)
                            // Nine tenths, so the next card's edge is always
                            // showing. A carousel of full-width cards is a
                            // carousel nobody scrolls, because nothing on
                            // screen says there is more than one.
                            .containerRelativeFrame(.horizontal, count: 10, span: 9, spacing: 0)
                            .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $visible)
            // Bleeds to the screen edges while the rest of the step stays
            // inset — a strip that stops short of the edge reads as having
            // ended. Matches the mapped-cards strip in My Automations.
            .padding(.horizontal, -AppTheme.Spacing.l)
            .contentMargins(.horizontal, AppTheme.Spacing.l, for: .scrollContent)

            dots
        }
    }

    /// The count, not decoration: with the ninth-of-a-card peek the reader
    /// knows there is a next one, and the dots are what say how many are
    /// left.
    private var dots: some View {
        HStack(spacing: AppTheme.Spacing.s) {
            ForEach(samples.indices, id: \.self) { index in
                Circle()
                    .fill(
                        index == (visible ?? 0)
                            ? AppTheme.Palette.textSecondary
                            : AppTheme.Palette.textSecondary.opacity(AppTheme.Opacity.fillStrong)
                    )
                    .frame(width: AppTheme.Size.dot, height: AppTheme.Size.dot)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

/// One notification, drawn as iOS draws it once it has been pressed.
///
/// **No app row.** The banner's first line — icon, "KEEPO", "now" — is real,
/// and it is also the one part of a notification that says nothing: the
/// reader is looking at this inside Keepo, on a screen titled "Stay on top
/// of your spending", so a badge repeating the app's own name spends the
/// widest line of the card on something already established. What is left is
/// what the notification actually tells you.
///
/// **Actions in a row, under a rule.** iOS stacks them full width, which on
/// a card this size turned four buttons into a table of four rows and made
/// the whole thing read as a settings list rather than a notification.
/// Inline capsules keep the notification the subject and the buttons its
/// trailer; `TagFlowLayout` wraps them onto a second line when a branch has
/// four, rather than shrinking or truncating any of them.
///
/// The **full-bleed rule above them is what makes them belong**. Sitting
/// loose on the same white as the message, the chips read as buttons that
/// happened to be under a notification rather than as part of it — which is
/// the one thing a still of a notification has to get right, since the whole
/// claim being made is that these arrive together. The rule is why it is
/// padded per section rather than once around the stack.
private struct NotificationStill: View {
    let resolution: CaptureLocalWrite.Resolution

    private var copy: CaptureNotificationCopy.Content {
        CaptureNotificationCopy.appliedLocally(
            resolution, amountE4: CaptureNotificationCopy.showcaseAmountE4
        )
    }

    private var actions: [UNNotificationAction] {
        CaptureQuickActions.build(for: resolution).actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(copy.title)
                    .font(AppTheme.Typography.bodyEmphasis)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(copy.body)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppTheme.Spacing.l)

            // The "both unknown" branch genuinely has no buttons, and a rule
            // over nothing would be a promise the real notification does not
            // keep.
            if !actions.isEmpty {
                Divider()
                TagFlowLayout(spacing: AppTheme.Spacing.s) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                        chip(action)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppTheme.Spacing.l)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The brand's top-level surface radius, which is also roughly what
        // iOS gives a notification, plus the lift that makes it read as a
        // thing resting *over* the screen rather than a panel set into it.
        .background(AppTheme.Palette.bgSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.surface))
        .elevation(.resting)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Example notification. \(copy.title). \(copy.body). "
                + "Buttons: \(actions.map(\.title).joined(separator: ", "))"
        )
    }

    /// `.destructive` is the only option that takes a colour, exactly as it
    /// does on the real thing.
    private func chip(_ action: UNNotificationAction) -> some View {
        Text(action.title)
            .font(AppTheme.Typography.label)
            .foregroundStyle(
                action.options.contains(.destructive)
                    ? AppTheme.Palette.statusNegative
                    : AppTheme.Palette.textPrimary
            )
            .lineLimit(1)
            .padding(.horizontal, AppTheme.Spacing.m)
            .frame(height: AppTheme.Size.icon)
            .background(AppTheme.Palette.fillSubtle, in: Capsule())
    }
}
