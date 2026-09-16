import AVKit
import KeepoCore
import SwiftUI

/// The Wallet automation, as a to-do list.
///
/// **A list of instructions is not the same thing as a list of tasks.** The
/// shared `ShortcutsWalkthroughView` — which Profile → My Automations still
/// uses, correctly — lays all four steps out at once as reference material
/// you read. That is right for somebody coming back to check what they did.
/// It is wrong here, where the user is doing the steps *now*, in another
/// app, one at a time, and needs to know where they are in a procedure they
/// keep leaving the phone for. Four open cards with four videos is also
/// four screens of scrolling before the first instruction.
///
/// So this is the same four steps with one open at a time: the current
/// card shows its purpose, its clip and whatever action it carries; the
/// finished ones collapse to a ticked line; and the next opens as soon as
/// one is ticked. The instructions themselves are still
/// `ShortcutsWalkthrough.steps`, so there remains exactly one copy of them
/// in the app.
///
/// Clips are optional by construction — `WalkthroughClipView` checks the
/// bundle and falls back to a poster — so this builds and runs against an
/// empty `videos/` folder, which is what it does today.
struct CaptureSetupChecklist: View {
    /// Which steps are ticked, by `WalkthroughStep.id`.
    @Binding var completed: Set<Int>

    @State private var expanded: Int?

    private var steps: [WalkthroughStep] { ShortcutsWalkthrough.steps }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.m) {
            ForEach(steps) { step in
                card(step)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(AppTheme.Motion.standard, value: expanded)
        .animation(AppTheme.Motion.standard, value: completed)
        .task { expanded = firstUnfinished }
    }

    private var firstUnfinished: Int? {
        steps.first { !completed.contains($0.id) }?.id
    }

    private func card(_ step: WalkthroughStep) -> some View {
        let isDone = completed.contains(step.id)
        let isOpen = expanded == step.id

        return VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            header(step, isDone: isDone, isOpen: isOpen)

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

                Button {
                    complete(step)
                } label: {
                    Text("Done")
                        .font(AppTheme.Typography.labelEmphasis)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: AppTheme.Size.touchTarget)
                        .overlay(Capsule().stroke(AppTheme.Palette.textSecondary, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(AppTheme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Palette.bgSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card))
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.card))
        .onTapGesture { if !isOpen { expanded = step.id } }
    }

    private func header(_ step: WalkthroughStep, isDone: Bool, isOpen: Bool) -> some View {
        HStack(spacing: AppTheme.Spacing.m) {
            marker(step, isDone: isDone)
            Text(step.title)
                .font(isOpen ? AppTheme.Typography.bodyEmphasis : AppTheme.Typography.body)
                // Never struck through. A finished step is still the record
                // of what was done, and this list is read while doing the
                // next one — a strike makes the line harder to re-read at
                // exactly the moment somebody wants to.
                .foregroundStyle(isDone ? AppTheme.Palette.textSecondary : AppTheme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(step.title)
        .accessibilityValue(isDone ? "Done" : "Not done")
    }

    /// The number until it is done, then the tick. Keeping the number while
    /// it is pending is what makes the collapsed list read as a sequence
    /// rather than as a set of unrelated checkboxes.
    @ViewBuilder
    private func marker(_ step: WalkthroughStep, isDone: Bool) -> some View {
        if isDone {
            Image(systemName: "checkmark.circle.fill")
                .font(AppTheme.Typography.bodyEmphasis)
                .foregroundStyle(AppTheme.Palette.statusPositive)
                .frame(width: AppTheme.Size.glyph, height: AppTheme.Size.glyph)
        } else {
            Text(verbatim: "\(step.id)")
                .font(AppTheme.Typography.captionEmphasis)
                .monospacedDigit()
                .foregroundStyle(AppTheme.Palette.textOnAccent)
                .frame(width: AppTheme.Size.glyph, height: AppTheme.Size.glyph)
                .background(AppTheme.Palette.brandPrimary, in: Circle())
        }
    }

    private func complete(_ step: WalkthroughStep) {
        completed.insert(step.id)
        expanded = firstUnfinished
    }
}
