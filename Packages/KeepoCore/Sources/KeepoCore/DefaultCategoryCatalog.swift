import Foundation

/// The categories onboarding offers on its Categories step, as data.
///
/// **"Other" is deliberately absent, and that is a schema constraint rather
/// than a taste.** The backend seeds exactly one `is_default` category per
/// kind at signup (`handle_new_user`), and
/// `categories_one_default_per_kind` enforces that there is never a second
/// — so nothing here may be `is_default`, and offering a second "Other"
/// would be offering a row the database would refuse.
///
/// Colours come from `CategoryAppearance.palette` and nowhere else: that
/// set is also the swatch row the icon catalogue offers, and a category the
/// user picked at setup must be recolourable to the same values as one they
/// make later. Icons are SF Symbols, matching what `CategoryAppearance`
/// already assigns by keyword — a category created here and the same
/// category typed by hand should not look different.
public enum DefaultCategoryCatalog {
    public static let all: [DefaultCategory] = expenses + income

    /// Fourteen, which is the number the Categories step's 3-column grid
    /// shows without scrolling on the smallest supported device.
    public static let expenses: [DefaultCategory] = [
        .init(key: .groceries, name: "Groceries", kind: .expense, icon: "cart.fill", color: "#34C759"),
        .init(key: .diningOut, name: "Dining Out", kind: .expense, icon: "fork.knife", color: "#FF9500"),
        .init(key: .transport, name: "Transport", kind: .expense, icon: "car.fill", color: "#007AFF"),
        .init(key: .housing, name: "Housing", kind: .expense, icon: "house.fill", color: "#A2845E"),
        .init(key: .utilities, name: "Utilities", kind: .expense, icon: "bolt.fill", color: "#FFCC00"),
        .init(key: .health, name: "Health", kind: .expense, icon: "heart.fill", color: "#FF2D55"),
        .init(key: .shopping, name: "Shopping", kind: .expense, icon: "bag.fill", color: "#AF52DE"),
        .init(key: .entertainment, name: "Entertainment", kind: .expense, icon: "gamecontroller.fill",
              color: "#5856D6"),
        .init(key: .travel, name: "Travel", kind: .expense, icon: "airplane", color: "#30B0C7"),
        .init(key: .subscriptions, name: "Subscriptions", kind: .expense, icon: "repeat", color: "#00C7BE"),
        .init(key: .fitness, name: "Fitness", kind: .expense, icon: "figure.run", color: "#FF3B30"),
        .init(key: .education, name: "Education", kind: .expense, icon: "book.fill", color: "#5AC8FA"),
        .init(key: .gifts, name: "Gifts", kind: .expense, icon: "gift.fill", color: "#FF6FB5"),
        .init(key: .pets, name: "Pets", kind: .expense, icon: "pawprint.fill", color: "#C98A3C")
    ]

    /// Nine, and a deliberately **darker** band than the expense list.
    ///
    /// No two categories anywhere in this catalogue share a colour any
    /// more. They used to: Transport and Education were both `#007AFF`,
    /// Housing and Pets and Rental were all `#A2845E`, and six of the seven
    /// original income rows simply borrowed an expense colour. In a grid
    /// scanned rather than read, two identical discs are read as the same
    /// thing twice — and the colour is the only part of a tile the eye uses
    /// at that speed.
    ///
    /// Income taking the deeper end of each hue is what makes twenty-three
    /// distinct colours possible without any pair sitting close: the two
    /// groups are never on screen at the same moment as peers, so they can
    /// occupy the same hues at different weights.
    public static let income: [DefaultCategory] = [
        .init(key: .salary, name: "Salary", kind: .income, icon: "banknote.fill", color: "#1D8348"),
        .init(key: .freelance, name: "Freelance", kind: .income, icon: "briefcase.fill", color: "#1A5276"),
        .init(key: .investments, name: "Investments", kind: .income, icon: "chart.line.uptrend.xyaxis",
              color: "#6C3483"),
        .init(key: .rental, name: "Rental", kind: .income, icon: "house.fill", color: "#7E5109"),
        .init(key: .refunds, name: "Refunds", kind: .income, icon: "arrow.uturn.left.circle.fill", color: "#117864"),
        .init(key: .bonus, name: "Bonus", kind: .income, icon: "star.fill", color: "#B7950B"),
        // Money arriving as a present, which is a different thing from the
        // expense row of the same name and needs its own key — the two are
        // opposite signs and can both exist on one account.
        .init(key: .giftsReceived, name: "Gifts", kind: .income, icon: "gift.fill", color: "#922B21"),
        .init(key: .interest, name: "Interest", kind: .income, icon: "percent", color: "#5D6D7E"),
        .init(key: .pension, name: "Pension", kind: .income, icon: "figure.and.child.holdinghands",
              color: "#4A235A")
    ]

    /// What the step starts with selected. Everything else is one tap away,
    /// and a category nobody uses is worse than one they add when they need
    /// it — so this is the short list almost everyone actually files
    /// against, not a recommendation of the whole catalogue.
    public static let preselected: [DefaultCategoryKey] = [
        .groceries, .diningOut, .transport, .housing, .utilities, .shopping, .salary
    ]

    public static func category(for key: DefaultCategoryKey) -> DefaultCategory? {
        all.first { $0.key == key }
    }
}

/// Stable across releases: the onboarding draft persists these, so a user
/// mid-flow when the app updates must find the same categories selected.
/// **Rename the `name`, never the case.**
public enum DefaultCategoryKey: String, Codable, Sendable, CaseIterable, Hashable {
    case groceries, diningOut, transport, housing, utilities, health, shopping
    case entertainment, travel, subscriptions, fitness, education, gifts, pets
    case salary, freelance, investments, rental, refunds, bonus
    // Added after the catalogue shipped. Cases are only ever appended: a
    // draft persisted mid-onboarding decodes this list by raw value, so
    // removing or renaming one would strand a half-finished setup.
    case giftsReceived, interest, pension
}

public struct DefaultCategory: Sendable, Equatable, Identifiable, Codable {
    public let key: DefaultCategoryKey
    public let name: String
    public let kind: PublicSchema.CategoryKind
    public let icon: String
    public let color: String

    public var id: DefaultCategoryKey { key }

    public init(key: DefaultCategoryKey, name: String, kind: PublicSchema.CategoryKind, icon: String, color: String) {
        self.key = key
        self.name = name
        self.kind = kind
        self.icon = icon
        self.color = color
    }
}
