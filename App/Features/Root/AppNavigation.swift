import Foundation
import KeepoCore

/// Which tab the app is on, and where one screen has asked it to go next.
///
/// Exists for one gesture: the chevron beside a category in the expanded
/// Cashflow widget, which opens that category's transactions for the period
/// being looked at. The user chose a **tab switch** over a pushed screen —
/// the dashboard stays where it was, and Transactions is where transactions
/// live, rather than a second copy of that list growing inside Home's own
/// navigation stack.
///
/// A shared object rather than a binding threaded down through Home: the
/// dashboard is four view layers below the tab bar, and passing a selection
/// binding through each of them would put a navigation concern into every
/// signature between here and a widget.
@Observable
@MainActor
final class AppNavigation {
    /// Three destinations, icon-only (`KeepoTabBar`). Profile is no longer
    /// among them: it is reached by tapping the avatar on the scope banner,
    /// which is on every one of these three screens, and presents as a
    /// sheet over whichever tab asked for it.
    enum Tab: Hashable, CaseIterable {
        case home
        case accounts
        case transactions
    }

    /// A screen inside the Profile tab that some other screen has asked to
    /// be pushed. Value-typed rather than a view, because the stack that has
    /// to push it lives in `MainTabView` and a widget four layers into Home
    /// has no business constructing one.
    enum ProfileDestination: Hashable {
        case household
        case automations
        case preferences
        case dataPrivacy
    }

    var tab: Tab = .home

    /// The Profile sheet's navigation stack. Driven by a path so a push can
    /// come from somewhere other than a tap on the row itself — the FX
    /// widget's "this is your base currency" note links straight to
    /// Preferences, and the scope banner's "Create Household" blank state
    /// links straight to Household.
    var profilePath: [ProfileDestination] = []

    /// Whether the Profile sheet is up. Profile stopped being a tab when
    /// the bar went down to three; presenting it modally from the shell
    /// keeps one copy of it (and one copy of `profilePath`) rather than a
    /// separate push inside each of the three tabs' own stacks.
    var isProfilePresented = false

    /// Which screen's Add button was pressed, waiting for that screen to
    /// act on it. Same set-then-clear shape as `transactionsRequest` below:
    /// all three tabs are mounted at once, so the request has to name its
    /// destination or every screen would answer it.
    var pendingAdd: Tab?

    /// A slice of the ledger some other screen has asked to be shown, waiting
    /// for the Transactions screen to pick it up. Cleared once applied, so
    /// switching back to the tab later doesn't silently re-apply a filter the
    /// user has since changed.
    var transactionsRequest: TransactionsRequest?

    /// Pressed the "+" beside the tab bar. What it adds is the current
    /// screen's business — a widget, an account, a transaction — so this
    /// only records where it was pressed.
    func requestAdd() {
        pendingAdd = tab
    }

    /// Consumed by the screen the request named. Returns false for every
    /// other screen, so the three `onChange` observers stay one line each.
    func consumeAdd(_ destination: Tab) -> Bool {
        guard pendingAdd == destination else { return false }
        pendingAdd = nil
        return true
    }

    func openTransactions(_ request: TransactionsRequest) {
        transactionsRequest = request
        tab = .transactions
    }

    /// Opens the Profile sheet on one screen. The path is **replaced**, not
    /// appended to: the ask is "show me this setting", and landing on it
    /// underneath whatever the user had left open would be a different
    /// screen with a wrong back button.
    func openProfile(_ destination: ProfileDestination) {
        profilePath = [destination]
        isProfilePresented = true
    }

    /// Opens the Profile sheet at its root — the scope banner's avatar.
    func openProfileRoot() {
        profilePath = []
        isProfilePresented = true
    }
}

/// A specific view of the transaction list, named by whoever is asking.
///
/// The period travels with the request rather than being left at whatever the
/// Transactions screen was last showing: the whole point of the gesture is
/// "these transactions, the ones behind the figure I just tapped", and landing
/// on the same category over a different month would answer a question nobody
/// asked.
struct TransactionsRequest: Equatable {
    var categoryId: UUID?
    /// `"transfer"` when the ask is about transfers, which have no category to
    /// filter by. Matches `TransactionFilter.kind`'s own vocabulary.
    var kind: String?
    var from: Date
    var through: Date

    /// Builds a request from a range of **UTC calendar days**, which is what
    /// every bucket boundary in the dashboard is.
    ///
    /// The translation is load-bearing, not tidying. The Transactions screen
    /// works in `Calendar.current`, so handing it a UTC midnight lands on the
    /// *previous* local day anywhere west of UTC — a July bucket arrived as
    /// "Jun 30 – Jul 30", off by one at both ends. Carrying the day across as
    /// year/month/day rather than as an instant is what keeps "July" July.
    ///
    /// `through` becomes the **end** of its day: the screen filters
    /// `occurred_at <= through`, and a midnight bound would silently drop
    /// everything that happened on the last day of the period.
    init(categoryId: UUID?, kind: String?, utcDays: ClosedRange<Date>) {
        self.categoryId = categoryId
        self.kind = kind
        self.from = Self.localDay(utcDays.lowerBound) ?? utcDays.lowerBound
        self.through = Self.localDay(utcDays.upperBound).map {
            Calendar.current.date(byAdding: DateComponents(day: 1, second: -1), to: $0) ?? $0
        } ?? utcDays.upperBound
    }

    /// The same calendar day, at midnight in the device's own calendar.
    private static func localDay(_ utcInstant: Date) -> Date? {
        let day = utcCalendar.dateComponents([.year, .month, .day], from: utcInstant)
        return Calendar.current.date(from: day)
    }
}
