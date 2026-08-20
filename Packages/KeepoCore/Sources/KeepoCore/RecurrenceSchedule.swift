import Foundation

/// Projects a recurring rule's future occurrences at read time — the local
/// counterpart to the server's `next_occurrences()`. Nothing here writes
/// anything: turning a due occurrence into a real `transactions` row is
/// `materialize_recurring()`'s job alone, on its own daily schedule. This
/// only answers "what is coming".
///
/// **Occurrence *k* is the anchor plus *k* whole periods, never the previous
/// occurrence plus one.** Repeated single steps drift across month ends: a
/// rule anchored on the 31st clamps to the 28th in February, and stepping
/// again from *that* lands on 28 March rather than back on the 31st, so the
/// rule would silently walk its own due date earlier every February.
/// Multiplying from the original anchor cannot drift, because every
/// occurrence is computed from the same fixed point.
public enum RecurrenceSchedule {
    /// Bounds the walk when an anchor is far in the past — a rule whose
    /// materialization has fallen months behind would otherwise iterate once
    /// per period since then. Ten years of weekly occurrences is far past any
    /// window a screen would ask for, and stops a corrupt anchor from
    /// spinning.
    private static let maximumSteps = 520

    /// Every occurrence of `frequency` anchored at `anchor` that falls inside
    /// `window`, in ascending order.
    ///
    /// An anchor *before* the window is normal and handled: the walk starts
    /// there and only collects what lands in range. That matters because a
    /// rule's `next_due_at` can sit in the past when materialization hasn't
    /// caught up yet, and silently dropping those would hide a bill that is
    /// genuinely still owed.
    public static func occurrences(
        anchoredAt anchor: Date,
        frequency: PublicSchema.RecurringFrequency,
        in window: ClosedRange<Date>,
        calendar: Calendar
    ) -> [Date] {
        var results: [Date] = []
        for step in 0 ..< maximumSteps {
            guard let date = calendar.date(
                byAdding: component(for: frequency), value: step * stride(for: frequency), to: anchor
            ) else { break }
            if date > window.upperBound { break }
            if date >= window.lowerBound { results.append(date) }
        }
        return results
    }

    /// Weekly is seven **days**, not one week-of-year: adding `.weekOfYear`
    /// is subject to the calendar's own week rules, and a recurring bill
    /// means "every seven days" regardless of where week boundaries fall.
    private static func component(for frequency: PublicSchema.RecurringFrequency) -> Calendar.Component {
        switch frequency {
        case .weekly: return .day
        case .monthly: return .month
        case .yearly: return .year
        }
    }

    private static func stride(for frequency: PublicSchema.RecurringFrequency) -> Int {
        frequency == .weekly ? 7 : 1
    }
}
