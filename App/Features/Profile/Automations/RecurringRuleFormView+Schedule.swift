import KeepoCore
import SwiftUI

// When the rule fires: how often, when the next one lands, and the one-tap
// calendar behind it. Split out of RecurringRuleFormView.swift for the
// project's file-length and type-body-length lints, same precedent as
// TransactionFormView+Date.swift.
//
// Nothing here is `private`, for that reason alone.

extension RecurringRuleFormView {
    /// How often, then when — read top to bottom as one sentence: "Monthly,
    /// next on 15 Oct".
    ///
    /// Frequency goes first because it is the rule's defining fact *and*
    /// because it decides what the chevrons underneath it do. The
    /// transaction form puts its date at the very top of the card and this
    /// sits in the same slot, so the two forms still open on the same
    /// question — this one just needs two controls to answer it.
    var scheduleBlock: some View {
        VStack(spacing: AppTheme.Spacing.m) {
            frequencyTrack
            periodStepper
        }
    }

    /// A faint track with a hairline border and the chosen option sitting in
    /// a capsule punched back to the card's own colour — the shape the
    /// dashboard's W/M/Y filter and the ledger's period picker both already
    /// use. The border is what says these three are one control and only one
    /// of them can be true.
    ///
    /// `WidgetSegment` is reused for the segments themselves, because what
    /// must never drift between these controls is the *selected* treatment.
    /// The track chrome is written out here rather than shared: its
    /// counterpart (`WidgetHeaderTrack`) is drawn on a widget header and the
    /// ledger's is drawn on a saturated brand colour, so there are two of
    /// these and this is the second neutral one — the point at which
    /// CLAUDE.md says duplication is still allowed and extraction is a guess.
    var frequencyTrack: some View {
        HStack(spacing: 0) {
            ForEach(PublicSchema.RecurringFrequency.displayOrder, id: \.self) { option in
                WidgetSegment(
                    isSelected: frequency == option,
                    action: { frequency = option },
                    label: { Text(option.shortLabel).frame(maxWidth: .infinity) }
                )
            }
        }
        .font(AppTheme.Typography.micro)
        .padding(AppTheme.Spacing.xs)
        .background(AppTheme.Palette.fillSubtle, in: Capsule())
        .overlay(Capsule().stroke(AppTheme.Palette.fillStrong, lineWidth: 1))
        .animation(AppTheme.Motion.quick, value: frequency)
        .sensoryFeedback(AppTheme.Feedback.selection, trigger: frequency)
    }

    /// The next occurrence, centred, with one period either side of it.
    ///
    /// **The chevrons step by a period, not by a day**, which is the whole
    /// difference between this and the transaction form's stepper. A rule
    /// moved "one forward" means the month after the one on screen — nudging
    /// a monthly rule to the 16th is a correction, and that is what the
    /// calendar behind the pill is for.
    ///
    /// They sit at the row's two ends rather than against the pill for the
    /// same reason they do on the transaction form: the control that shifts
    /// the schedule and the control that opens a calendar should be nowhere
    /// near each other's thumb.
    var periodStepper: some View {
        HStack(spacing: AppTheme.Spacing.s) {
            periodStep(-1, icon: "chevron.left", label: "One \(frequency.shortLabel.lowercased()) earlier")
            Spacer(minLength: AppTheme.Spacing.s)
            datePill
            Spacer(minLength: AppTheme.Spacing.s)
            periodStep(1, icon: "chevron.right", label: "One \(frequency.shortLabel.lowercased()) later")
        }
        .sensoryFeedback(AppTheme.Feedback.selection, trigger: dateSteps)
    }

    /// Unbounded in both directions, like the calendar behind the pill. A
    /// rule's `next_due_at` can legitimately sit in the past — that is what
    /// materialization falling behind looks like, and a stepper that refused
    /// to go there would hide the one state worth noticing.
    ///
    /// `hitTarget` and not a 44pt frame: the finger gets HIG's area without
    /// the row growing to match it.
    func periodStep(_ periods: Int, icon: String, label: String) -> some View {
        Button {
            let step = frequency.step
            guard let stepped = Calendar.current.date(
                byAdding: step.component, value: step.value * periods, to: nextDueAt
            ) else { return }
            nextDueAt = stepped
            dateSteps += 1
        } label: {
            Image(systemName: icon)
                .font(AppTheme.Typography.captionEmphasis)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .padding(AppTheme.Spacing.xs)
                .hitTarget()
        }
        .buttonStyle(.pressableCard)
        .accessibilityLabel(label)
    }

    /// Outlined rather than filled, for the reason the transaction form's is:
    /// it sits on the card's own surface, and a second filled capsule there
    /// would compete with the amount for weight.
    ///
    /// It leads with "Next" because a bare date on a screen about a repeating
    /// instruction is ambiguous — it could as easily be the day the rule was
    /// made.
    var datePill: some View {
        Button {
            isPickingDate = true
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: "calendar")
                    .font(AppTheme.Typography.micro)
                Text(nextDueLabel)
                    .font(AppTheme.Typography.label)
            }
            .foregroundStyle(AppTheme.Palette.textPrimary)
            .padding(.horizontal, AppTheme.Spacing.m)
            .padding(.vertical, AppTheme.Spacing.s)
            .overlay {
                Capsule().strokeBorder(AppTheme.Palette.fillStrong, lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.pressableCard)
    }

    /// "Next: Today" / "Next: 15 Oct 2026". Today and tomorrow get their
    /// names — those are what the user is actually thinking, and for a rule
    /// the interesting direction is forward, which is why tomorrow appears
    /// here where the transaction form names yesterday.
    var nextDueLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(nextDueAt) { return "Next: Today" }
        if calendar.isDateInTomorrow(nextDueAt) { return "Next: Tomorrow" }
        return "Next: " + nextDueAt.formatted(date: .abbreviated, time: .omitted)
    }

    /// **Picking a date is one tap**, same contract as the transaction
    /// form's: the day the user taps is the answer, and a Done button behind
    /// it would ask them to confirm a choice already made.
    ///
    /// Dismissing on the *value* is what keeps the month chevrons and the
    /// year list usable — those move the calendar without choosing anything.
    /// The close button is not a second confirm; it is the way out of the one
    /// case a selection cannot cover, which is tapping the day that is
    /// already selected.
    var datePickerSheet: some View {
        NavigationStack {
            DatePicker("Next due", selection: $nextDueAt, displayedComponents: [.date])
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("Next Due")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { isPickingDate = false } label: { Image(systemName: "xmark") }
                    }
                }
                .onChange(of: nextDueAt) { _, _ in isPickingDate = false }
                .sensoryFeedback(AppTheme.Feedback.selection, trigger: nextDueAt)
        }
        .presentationDetents([.medium])
    }
}
