import Foundation

/// A category's icon and color are purely presentational — nothing else in
/// the schema looks a category up by either (see the DB migration's own
/// comment) — so the heuristics and curated set live here, one place, used
/// both when a new category is created and whenever the picker needs its
/// options.
public enum CategoryAppearance {
    /// Checked in order, first match wins — deliberately ordered from most
    /// to least specific ("paycheck" before a generic income fallback
    /// would never be reached otherwise since there is no single generic
    /// income keyword to place after it).
    private static let keywordIcons: [(keywords: [String], icon: String)] = [
        (["grocery", "groceries", "supermarket", "food"], "cart.fill"),
        (["restaurant", "dining", "coffee", "cafe"], "fork.knife"),
        (["rent", "mortgage", "housing", "home"], "house.fill"),
        (["transport", "gas", "fuel", "car", "commute", "parking"], "car.fill"),
        (["flight", "travel", "hotel", "vacation"], "airplane"),
        (["health", "medical", "doctor", "pharmacy"], "heart.fill"),
        (["shopping", "clothes", "clothing"], "bag.fill"),
        (["entertainment", "movie", "streaming", "game", "games"], "gamecontroller.fill"),
        (["utility", "utilities", "electric", "water", "internet", "phone"], "bolt.fill"),
        (["education", "school", "tuition", "books"], "book.fill"),
        (["gift", "gifts", "donation", "charity"], "gift.fill"),
        (["pet", "pets"], "pawprint.fill"),
        (["fitness", "gym", "sport", "sports"], "figure.run"),
        (["salary", "paycheck", "wage", "wages"], "banknote.fill"),
        (["freelance", "invoice", "client"], "briefcase.fill"),
        (["interest", "dividend", "investment", "investments"], "chart.line.uptrend.xyaxis"),
        (["refund", "reimbursement"], "arrow.uturn.left.circle.fill")
    ]

    private static let fallbackExpenseIcon = "tag.fill"
    private static let fallbackIncomeIcon = "dollarsign.circle.fill"

    public static func defaultIcon(forName name: String, kind: PublicSchema.CategoryKind) -> String {
        let normalized = name.lowercased()
        for entry in keywordIcons where entry.keywords.contains(where: normalized.contains) {
            return entry.icon
        }
        return kind == .income ? fallbackIncomeIcon : fallbackExpenseIcon
    }

    /// A curated palette rather than uniform-random RGB — every value here
    /// reads clearly against both a white icon glyph and the app's own
    /// light/dark backgrounds, which arbitrary random hues can't promise.
    /// Public because it is also the swatch row `IconCatalogView` offers —
    /// the colours a new category is assigned and the colours a user can
    /// pick must be the same set, not two lists that drift.
    ///
    /// **Twenty-four, in two bands.** The first twelve are the originals and
    /// stay first, so every existing category keeps its colour and the
    /// swatch row opens on the same familiar set. The second twelve are
    /// deeper variants of the same hues, added because the default
    /// catalogue grew to twenty-three categories and a twelve-colour
    /// palette cannot give twenty-three of anything a colour of its own —
    /// seven pairs were sharing one, and in a grid that is scanned rather
    /// than read, two identical discs are read as the same thing twice.
    ///
    /// Deeper rather than more hues on purpose: there are only so many
    /// distinguishable hues, and a second one of each at a different weight
    /// separates cleanly where a twenty-fourth hue would have sat between
    /// two neighbours and muddied both.
    public static let palette = [
        "#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#00C7BE", "#30B0C7",
        "#007AFF", "#5856D6", "#AF52DE", "#FF2D55", "#A2845E", "#8E8E93",
        "#922B21", "#7E5109", "#B7950B", "#1D8348", "#117864", "#5D6D7E",
        "#1A5276", "#4A235A", "#6C3483", "#FF6FB5", "#C98A3C", "#5AC8FA"
    ]

    public static func randomColor() -> String {
        palette.randomElement() ?? "#8E8E93"
    }
}
