import KeepoCore
import SwiftUI

// When the transaction happened: the pill on the card, how that pill reads,
// and the one-tap calendar behind it. Split out of TransactionFormView.swift
// for the project's file-length and type-body-length lints, same precedent
// as TransactionFormView+Transfer.swift.
//
// Nothing here is `private`, for that reason alone.

extension TransactionFormView {
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
            DatePicker("Date", selection: $occurredAt, displayedComponents: [.date])
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
