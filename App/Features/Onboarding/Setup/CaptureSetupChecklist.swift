import AVKit
import KeepoCore
import SwiftUI

/// The Wallet automation, as a checklist you tick.
///
/// **A list of instructions is not the same thing as a list of tasks.** The
/// shared `ShortcutsWalkthroughView` — which Profile → My Automations still
/// uses, correctly — lays all four steps out at once as reference material
/// you read. That is right for somebody coming back to check what they did.
/// It is wrong here, where the user is doing the steps *now*, in another
/// app, one at a time, and needs to know where they are in a procedure they
/// keep leaving the phone for.
///
/// **Sequential, and enforced.** Only the first unticked step is live;
/// everything after it is locked. These steps genuinely cannot be done out
/// of order — you cannot point an automation at a shortcut you have not
/// installed — so a list that let you tick step 4 first would be letting
/// you record something that did not happen, and the button at the end
/// trusts these ticks. Unticking a step unticks everything after it for the
/// same reason.
///
/// The box does the work: tapping it is the whole interaction, the way it
/// is in Notes or Reminders. An earlier version had a "Done" button inside
/// each card, which is the same tap made twice as far away and reads as a
/// form rather than as a list.
///
/// The instructions are still `ShortcutsWalkthrough.steps`, so there remains
/// exactly one copy of them in the app. Clips are optional by construction —
/// `WalkthroughClipView` checks the bundle and falls back — so this builds
/// and runs against an empty `videos/` folder, which is what it does today.
struct CaptureSetupChecklist: View {
    /// Which steps are ticked, by `WalkthroughStep.id`.
    @Binding var completed: Set<Int>

    private var steps: [WalkthroughStep] { ShortcutsWalkthrough.steps }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.m) {
            ForEach(steps) { step in
                card(step)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(AppTheme.Motion.standard, value: completed)
    }

    /// Everything before it is ticked. The first unticked step is the only
    /// live one; a ticked step stays live so it can be unticked.
    private func isUnlocked(_ step: WalkthroughStep) -> Bool {
        steps.filter { $0.id < step.id }.allSatisfy { completed.contains($0.id) }
    }

    /// Open only while it is the step being worked on. A ticked step
    /// collapses to its title — it is a record, not an instruction any more
    /// — and a locked one has nothing to show yet.
    private func isExpanded(_ step: WalkthroughStep) -> Bool {
        isUnlocked(step) && !completed.contains(step.id)
    }

    private func card(_ step: WalkthroughStep) -> some View {
        let isDone = completed.contains(step.id)
        let isLive = isUnlocked(step)
        let isOpen = isExpanded(step)

        return VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.m) {
                checkbox(isDone: isDone, isLive: isLive)
                    .onTapGesture { toggle(step) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(isDone ? "Mark step \(step.id) as not done" : "Mark step \(step.id) as done")

                Text(step.title)
                    .font(isOpen ? AppTheme.Typography.bodyEmphasis : AppTheme.Typography.body)
                    // Never struck through. A finished step is still the
                    // record of what was done, and this list is read while
                    // doing the next one — a strike makes the line harder to
                    // re-read at exactly the moment somebody wants to.
                    .foregroundStyle(isLive ? AppTheme.Palette.textPrimary : AppTheme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isOpen {
                Text(step.detail)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // The first step is the only one with something to press —
                // every other step happens inside the Shortcuts app, where
                // Keepo has no buttons to offer.
                if step.id == steps.first?.id {
                    ShortcutInstallButton()
                }

                WalkthroughClipView(clip: step.clip)
            }
        }
        .padding(AppTheme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Palette.bgSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card))
        .accessibilityElement(children: .contain)
    }

    /// A rounded square, empty until it is ticked — Notes' and Reminders'
    /// vocabulary, which is the point: a checklist should be tickable
    /// without anybody explaining that it is.
    ///
    /// A locked box is drawn in the faintest of the three text colours
    /// rather than hidden. The row still has to look like a step of the
    /// procedure, and a card with no box beside it reads as a heading.
    private func checkbox(isDone: Bool, isLive: Bool) -> some View {
        RoundedRectangle(cornerRadius: AppTheme.Radius.control * 0.5)
            .strokeBorder(
                isDone ? AppTheme.Palette.brandPrimary
                    : (isLive ? AppTheme.Palette.textSecondary : AppTheme.Palette.fillStrong),
                lineWidth: 1.5
            )
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.control * 0.5)
                    .fill(isDone ? AppTheme.Palette.brandPrimary : .clear)
            )
            .frame(width: AppTheme.Size.glyph, height: AppTheme.Size.glyph)
            .overlay {
                if isDone {
                    Image(systemName: "checkmark")
                        .font(AppTheme.Typography.captionEmphasis)
                        .foregroundStyle(AppTheme.Palette.textOnAccent)
                }
            }
            .contentShape(Rectangle())
            .animation(AppTheme.Motion.quick, value: isDone)
    }

    private func toggle(_ step: WalkthroughStep) {
        guard isUnlocked(step) else { return }
        var next = completed
        if next.contains(step.id) {
            // Unticking a step unticks everything after it: the list is a
            // sequence, so a later step cannot still be done once an earlier
            // one is not — and leaving those ticks would let the button at
            // the end believe a procedure that no longer happened.
            for later in steps where later.id >= step.id { next.remove(later.id) }
        } else {
            next.insert(step.id)
        }
        completed = next
    }
}
