import Foundation
import KeepoCore

/// How a recurrence frequency is worded, in one place.
///
/// Two screens name the same three values — the Recurring list's subtitle
/// and the rule form's frequency track — and they need different lengths of
/// the same word, not different words. Kept together so "Monthly" and
/// "Every month" can never drift into being two different ideas.
extension PublicSchema.RecurringFrequency {
    /// The three, in the order a picker should offer them — shortest period
    /// first, which is also the order the server's own enum declares.
    ///
    /// Written out rather than taken from `CaseIterable`: the generated type
    /// does not conform, and conforming it from this module would be a
    /// retroactive conformance to a type `supabase gen types swift` rewrites
    /// after every migration. An explicit array also makes the display order
    /// a decision rather than a by-product of codegen.
    static let displayOrder: [Self] = [.weekly, .monthly, .yearly]

    /// "Every week" / "Every month" / "Every year" — a phrase, for a line of
    /// prose under a row's title.
    var everyLabel: String {
        switch self {
        case .weekly: return "Every week"
        case .monthly: return "Every month"
        case .yearly: return "Every year"
        }
    }

    /// The one-word form, for the form's segmented track: three options
    /// share one row there, and "Every month" does not fit in a third of it.
    var shortLabel: String {
        switch self {
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        }
    }

    /// How far one step of the rule's own stepper moves. A recurring rule's
    /// "next one" is a period away, never a day — which is what makes the
    /// chevrons beside the date pill mean something different here than they
    /// do on the transaction form.
    var step: (component: Calendar.Component, value: Int) {
        switch self {
        // Seven days, not one week-of-year — same reasoning as
        // `RecurrenceSchedule.component`, and the same reasoning the
        // server's own `next_occurrence_date` uses.
        case .weekly: return (.day, 7)
        case .monthly: return (.month, 1)
        case .yearly: return (.year, 1)
        }
    }
}
