import KeepoCore
import SwiftUI

// When the transaction happened: the pill on the card, how that pill reads,
// and the one-tap calendar behind it. Split out of TransactionFormView.swift
// for the project's file-length and type-body-length lints, same precedent
// as TransactionFormView+Transfer.swift.
//
// Nothing here is `private`, for that reason alone.

extension TransactionFormView {
    /// The date, centred on the card, with a day either side of it.
    ///
    /// Most corrections to a date are one day: an evening's spending
    /// entered the next morning, a receipt found in a pocket. Routing that
    /// through the calendar costs a tap to open it, a month grid to read
    /// and a tap to answer — for an answer that is always the cell next to
    /// the one already selected. The chevrons do it in place; the pill is
    /// still there for anywhere further away.
    ///
    /// They sit at the row's two ends rather than against the pill, so the
    /// control that changes the date by a day and the control that opens a
    /// calendar are nowhere near each other's thumb.
    var dateStepper: some View {
        HStack(spacing: AppTheme.Spacing.s) {
            dayStep(-1, icon: "chevron.left", label: "Previous day")
            Spacer(minLength: AppTheme.Spacing.s)
            datePill
            Spacer(minLength: AppTheme.Spacing.s)
            dayStep(1, icon: "chevron.right", label: "Next day")
        }
        .sensoryFeedback(AppTheme.Feedback.selection, trigger: dateSteps)
    }

    /// Unbounded forward, exactly like the calendar behind the pill: the
    /// ledger holds future rows — a bill entered early, a recurring rule's
    /// next occurrence — and a stepper that stopped at today would contradict
    /// the picker it sits beside. Backward it stops where the calendar does,
    /// at `earliestAllowedDate`.
    ///
    /// `hitTarget` and not a 44pt frame: the finger gets HIG's area
    /// without the header growing to match it.
    func dayStep(_ days: Int, icon: String, label: String) -> some View {
        let stepped = Calendar.current.date(byAdding: .day, value: days, to: occurredAt)
        let isBeforeEarliest = stepped.map { date in earliestAllowedDate.map { date < $0 } ?? false } ?? true
        return Button {
            guard let stepped, !isBeforeEarliest else { return }
            occurredAt = stepped
            dateSteps += 1
        } label: {
            // Dimmed by hand: the explicit colour overrides the one
            // `.disabled` would otherwise fade to.
            Image(systemName: icon)
                .font(AppTheme.Typography.captionEmphasis)
                .foregroundStyle(isBeforeEarliest ? AppTheme.Palette.textTertiary : AppTheme.Palette.textSecondary)
                .padding(AppTheme.Spacing.xs)
                .hitTarget()
        }
        .buttonStyle(.pressableCard)
        .disabled(isBeforeEarliest)
        .accessibilityLabel(label)
    }

    /// Outlined rather than filled: it sits on the card's own surface, and a
    /// second filled capsule there competed with the amount for weight. The
    /// two most recent days get their names instead of their dates — "Today"
    /// is what the user is actually thinking, and it is also the value they
    /// most need to be able to confirm at a glance.
    var datePill: some View {
        Button {
            isPickingDate = true
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: "calendar")
                    .font(AppTheme.Typography.micro)
                Text(dateLabel)
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

    var dateLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(occurredAt) { return "Today" }
        if calendar.isDateInYesterday(occurredAt) { return "Yesterday" }
        return occurredAt.formatted(date: .abbreviated, time: .omitted)
    }

    /// **Picking a date is one tap.** The day the user taps is the answer;
    /// a Done button behind it asks them to confirm a choice they have
    /// already made, on the field most entries change.
    ///
    /// Dismissing on the *value* rather than on a tap is what keeps the
    /// month chevrons and the year list usable: those move the calendar
    /// without choosing anything, so they leave `occurredAt` alone and the
    /// sheet stays up.
    ///
    /// The close button is not a second way to confirm. It is the way out of
    /// the one case a selection cannot cover: tapping the day that is already
    /// selected changes nothing, so nothing would dismiss.
    var datePickerSheet: some View {
        NavigationStack {
            // A partner cannot date an entry before the account was shared
            // with them; the calendar greys those days out.
            DatePicker(
                "Date", selection: $occurredAt, in: (earliestAllowedDate ?? .distantPast)...,
                displayedComponents: [.date]
            )
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("Date")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { isPickingDate = false } label: { Image(systemName: "xmark") }
                    }
                }
                .onChange(of: occurredAt) { _, _ in isPickingDate = false }
                .sensoryFeedback(AppTheme.Feedback.selection, trigger: occurredAt)
        }
        .presentationDetents([.medium])
    }
}
