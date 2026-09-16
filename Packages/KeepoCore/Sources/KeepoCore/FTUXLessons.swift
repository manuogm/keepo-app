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
/// **The scope-banner swipe is deliberately not here.** It is the one
/// gesture that earns an interruption rather than a tip, so it is a
/// hand-rolled spotlight instead: TipKit popovers cannot dim the screen and
/// cut a hole in it, and the whole point there is to show the banner while
/// everything else recedes.
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
    /// Ordered as the tour reads them, not as they fire — a user who opens
    /// "Show me around" is reading a page, not retracing their session.
    public static let all: [FTUXLesson] = [scope, accounts, categories, widgets, needsReview, privacy, add]

    /// Listed for the tour but never a tip: it is the spotlight's lesson,
    /// and it is here so the tour can state it alongside the rest.
    public static let scope = FTUXLesson(
        id: "scope",
        title: "Swipe the header to change scope",
        message: "Mine, shared, or everything together — it changes what every number in Keepo means.",
        symbol: "rectangle.on.rectangle.angled"
    )

    public static let accounts = FTUXLesson(
        id: "accounts",
        title: "Drag to convert an account",
        message: "Move a row between Everyday and Investments and it becomes that kind. Nothing is lost.",
        symbol: "arrow.up.arrow.down"
    )

    public static let categories = FTUXLesson(
        id: "categories",
        title: "Tap a category to edit it",
        message: "Rename it, recolour it, or pick a different icon. Every category is yours to change.",
        symbol: "hand.tap"
    )

    public static let widgets = FTUXLesson(
        id: "widgets",
        title: "Long-press a widget to rearrange",
        message: "Drag it where you want it, or add another from the button underneath.",
        symbol: "square.grid.2x2"
    )

    public static let needsReview = FTUXLesson(
        id: "needsReview",
        title: "This is what Keepo captured",
        message: "Purchases land here for a glance. Confirm one, or fix anything that looks off.",
        symbol: "tray.full"
    )

    public static let privacy = FTUXLesson(
        id: "privacy",
        title: "Hide every figure at once",
        message: "Tap the eye when someone is looking over your shoulder. Long-press it to change scope.",
        symbol: "eye.slash"
    )

    public static let add = FTUXLesson(
        id: "add",
        title: "Add anything from here",
        message: "A transaction, an account, a category, a transfer — this button is all of them.",
        symbol: "plus"
    )
}
