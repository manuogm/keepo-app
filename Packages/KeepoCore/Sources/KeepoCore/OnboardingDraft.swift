import Foundation

/// Everything the setup flow has collected so far, and **nothing that has
/// reached the server**.
///
/// **One commit point, at the end.** The flow this replaces wrote the
/// account and completed onboarding from inside step 4, so abandoning after
/// that left an orphan account behind and Back was only correct by
/// accident. Holding every step in one value gives three things at
/// once: Back is trivially correct everywhere, an abandoned flow leaves
/// nothing, and failure is handled in one place instead of four.
///
/// **It is persisted because the capture step sends the user to Shortcuts.** They are
/// gone for minutes, and iOS may *terminate* Keepo in that time rather than
/// merely background it — so `@State` alone loses the flow, which is what
/// today's version does. Written to `UserDefaults` on every step change,
/// alongside the other device-local keys and for the same documented
/// reason: this is progress state, not data about the user's money.
///
/// `Codable` rather than a sequence of stored properties on a view model so
/// that persistence is one `JSONEncoder` call and the whole thing is
/// testable without a UI.
public struct OnboardingDraft: Codable, Equatable, Sendable {
    public var step: SetupStep
    public var baseCurrency: String?
    /// The id is minted **here**, not at commit: client-generated UUIDs are
    /// this codebase's convention precisely so a retried write lands on the
    /// same row instead of duplicating it.
    public var account: DraftAccount?
    public var selectedCategories: [DefaultCategoryKey]
    /// **Order is the hierarchy** — the dashboard is built by appending in
    /// exactly this sequence, so this is an array and never a `Set`.
    public var selectedMetrics: [DashboardWidgetKind]
    /// Whether the notification permission has been *asked for*, which is
    /// not whether it was granted — iOS only ever asks once, so the flow
    /// must not offer the button a second time as though it would work.
    public var notificationAsked: Bool
    /// How far through the Shortcuts walkthrough the user got, so leaving
    /// for Shortcuts and coming back lands on the step they were on.
    public var walkthroughStep: Int
    /// Set when a test capture has actually arrived — the real pass
    /// condition for capture setup, and the thing Profile → My Automations
    /// reads to say "Working" rather than "Waiting for your first purchase".
    public var captureVerifiedAt: Date?

    public init(
        step: SetupStep = .currency,
        baseCurrency: String? = nil,
        account: DraftAccount? = nil,
        selectedCategories: [DefaultCategoryKey] = DefaultCategoryCatalog.preselected,
        selectedMetrics: [DashboardWidgetKind] = [.netWorth],
        notificationAsked: Bool = false,
        walkthroughStep: Int = 0,
        captureVerifiedAt: Date? = nil
    ) {
        self.step = step
        self.baseCurrency = baseCurrency
        self.account = account
        self.selectedCategories = selectedCategories
        self.selectedMetrics = selectedMetrics
        self.notificationAsked = notificationAsked
        self.walkthroughStep = walkthroughStep
        self.captureVerifiedAt = captureVerifiedAt
    }
}

/// The setup screens. Nine in the original brief — the card-naming screen
/// was cut once the prebuilt shortcut removed the need to type a card
/// identifier by hand, and the profile screen (a name and a photo) was cut
/// on 2026-10-01 for adding nothing the app needs; both stay editable in
/// My Profile.
///
/// `Int` raw values so the progress dots and "is this before that?" are
/// arithmetic rather than a `switch`, and **stable** because a persisted
/// draft names its step by this value — which is why the first case is 1,
/// not 0. A draft saved on the removed profile step (0) fails to decode and
/// the flow starts clean.
public enum SetupStep: Int, Codable, Sendable, CaseIterable, Comparable {
    case currency = 1
    case account = 2
    case capture = 3
    case categories = 4
    case dashboard = 5
    case committing = 6
    case allSet = 7

    public static func < (lhs: SetupStep, rhs: SetupStep) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The dots only count the steps the user is *working* through. The
    /// commit and the all-set screen are the end of the flow, not two more
    /// things to do, and showing 5-of-7 on a screen with nothing to answer
    /// would be counting the applause.
    public static let progressSteps: [SetupStep] = [
        .currency, .account, .capture, .categories, .dashboard
    ]

    /// **Only `.currency` has no Skip.** The wheel always holds a value —
    /// `onboarded_requires_base_currency` is a CHECK, so the step cannot
    /// produce "nothing" even in principle — which made Skip there a second
    /// button running the identical code path as Next, three seconds later
    /// and in a different corner. A control that cannot do anything the
    /// adjacent control does not already do is noise on a screen whose
    /// whole job is one decision.
    ///
    /// `.account` was the other exclusion, on the argument that a skipped
    /// account leaves an app with nowhere to hold money. **Reversed
    /// 2026-10-01**: the app has a "no accounts" empty state that leads
    /// back to creating one, so skipping is a postponement, not a dead end.
    /// It is also the one Skip that means "no value" rather than "accept
    /// the default" — there is no honest default for an account.
    public var isSkippable: Bool { self != .currency }

    public var next: SetupStep? { SetupStep(rawValue: rawValue + 1) }
    public var previous: SetupStep? { SetupStep(rawValue: rawValue - 1) }
}

/// The first account, as the user described it — not yet a row.
public struct DraftAccount: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: PublicSchema.AccountKind
    /// Usually the base currency, but not necessarily: an expat's first
    /// account is often not in the currency they think in, and the feature
    /// deck sells exactly that.
    public var currency: String
    public var openingBalanceE4: Int64
    public var icon: String
    public var color: String

    public init(
        id: UUID = UUID(),
        name: String = "",
        kind: PublicSchema.AccountKind = .regular,
        currency: String,
        openingBalanceE4: Int64 = 0,
        icon: String = "banknote",
        color: String = "#8E8E93"
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.currency = currency
        self.openingBalanceE4 = openingBalanceE4
        self.icon = icon
        self.color = color
    }
}
