import Foundation

/// The handful of things about Keepo that are worth pointing out, as data.
///
/// **One copy of each lesson, two places it appears.** Each is shown
/// just-in-time as a TipKit tip on the screen it is about, and all of them
/// are listed together on the replayable "Show me around" screen. Two
/// hand-written copies of the same sentence would drift the first time one
/// of these interactions changed, and the drift would be invisible —
/// nobody sees both surfaces at once.
///
/// **All but one are coach marks**, drawn by `SpotlightOverlay`: the screen
/// dims, a hole opens around the one control the lesson is about, and a card
/// points at it. Every lesson here teaches a **gesture on a specific
/// control** — swipe this, drag that, press here — and a popover that merely
/// sits *near* the control cannot say *this one*.
///
/// **The order of `all` is the order they arrive in**, not just the order
/// the tour prints them: the coordinator shows whichever of the lessons a
/// screen is offering comes first in this list. Two coach marks on one
/// screen therefore have a defined sequence wherever they are asked for.
public struct FTUXLesson: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    /// One sentence. A tip that needs a paragraph is a feature that needs
    /// redesigning.
    public let message: String
    /// SF Symbol, shown in both surfaces.
    public let symbol: String

    public init(id: String, title: String, message: String, symbol: String) {
        self.id = id
        self.title = title
        self.message = message
        self.symbol = symbol
    }
}

public enum FTUXLessons {
    /// Screen by screen, in the order each screen shows them: the Dashboard
    /// three, then the two on Accounts, then the two on Transactions.
    public static let all: [FTUXLesson] = [
        scope, privacy, widgets, accounts, add, swipeDelete, needsReview
    ]

    /// A coach mark, not a tip. **The message is a lead-in, not the
    /// lesson**: this is the one spotlight whose body is a list rather than
    /// a sentence, and the three scopes themselves are named and described
    /// by `AccountScope.title` / `.caption` in the app, so the tour and the
    /// banner cannot come to disagree about what "Household" filters.
    public static let scope = FTUXLesson(
        id: "scope",
        title: "Swipe header to change scope",
        message: "3 scopes to filter your data:",
        symbol: "rectangle.on.rectangle.angled"
    )

    /// A coach mark on the first account row — the gesture needs a row to
    /// be performed on, and the spotlight leaves that row draggable while
    /// it is up.
    public static let accounts = FTUXLesson(
        id: "accounts",
        title: "Drag to convert",
        message: "Drag and drop accounts between groups to change their type between Everyday "
            + "and Investment.",
        symbol: "arrow.up.arrow.down"
    )

    /// A coach mark on the first widget. A tapping hand rather than a grid
    /// glyph: the lesson is the press, not the thing being pressed.
    ///
    /// **An SF Symbol rather than Keepo's own `icon-tap`.** The asset is a
    /// 1px-stroke line drawing that reads as hairline beside a semibold
    /// title, and its stroke is fixed in the artwork — an SF Symbol takes
    /// the weight of the text it sits next to, which is the whole reason
    /// the other cards look right.
    public static let widgets = FTUXLesson(
        id: "widgets",
        title: "Long-press for Edit Mode",
        message: "Drag and drop widgets around to rearrange your dashboard as you want.",
        symbol: "hand.tap"
    )

    /// A coach mark on the inbox drawer. **The message is a lead-in**: the
    /// two things that put something in the inbox are listed under it, each
    /// against its own glyph — see `SpotlightOverlay`.
    ///
    /// An SF Symbol rather than `icon-inbox`, for the same reason `widgets`
    /// is: the asset's stroke cannot follow the title's weight. `envelope`
    /// is the closest match to the glyph on the drawer itself.
    public static let needsReview = FTUXLesson(
        id: "needsReview",
        title: "This is Keepo's inbox",
        message: "It is only visible when your input is needed for:",
        symbol: "envelope"
    )

    /// A coach mark on the first transaction row.
    ///
    /// **Two sentences, and the second is about a different screen on
    /// purpose.** Left-swiping a row means two different things in Keepo —
    /// gone forever here, archived on Accounts — and the moment somebody is
    /// being taught the first is the moment to say the second, before they
    /// try it somewhere it does not mean that.
    public static let swipeDelete = FTUXLesson(
        id: "swipeDelete",
        title: "Swipe to Delete",
        message: "Deleting a transaction is irreversible.\nSwipe left an account to Archive.",
        symbol: "hand.draw"
    )

    /// A coach mark on the eye in the Dashboard's banner.
    ///
    /// It used to end "Long-press it to change scope", which was true of a
    /// long-press that no longer exists — the carousel is how scope changes
    /// now, and `scope` is the lesson that teaches it.
    public static let privacy = FTUXLesson(
        id: "privacy",
        title: "Hide every figure at once",
        message: "Tap the eye when someone is looking over your shoulder.",
        symbol: "eye.slash"
    )

    /// A coach mark on the Add button, which is the one control that sits
    /// outside every screen — so pointing at it is the only way to say
    /// *this* button.
    public static let add = FTUXLesson(
        id: "add",
        title: "Add anything",
        message: "A new transaction, account, category or widget. This button gets you all.",
        symbol: "plus"
    )
}
