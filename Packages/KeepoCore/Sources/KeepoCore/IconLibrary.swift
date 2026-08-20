import Foundation

/// The one icon catalogue every "pick an icon" surface draws from —
/// accounts and categories both, per the shared `IconCatalogView` they now
/// share. Grouped into families because a flat 90-icon grid is a scavenger
/// hunt: the grouping is the search affordance, which is why this is
/// ordered data rather than a `Set`.
///
/// `CategoryAppearance`/`AccountAppearance` keep owning the *defaulting*
/// heuristics (which icon a brand-new category or account starts on) —
/// that's domain logic about naming and kind. This owns only the menu of
/// everything a user may pick instead, so the two never drift into separate
/// lists again.
public enum IconLibrary {
    public struct Family: Identifiable, Sendable, Hashable {
        public let name: String
        public let icons: [String]
        public var id: String { name }

        public init(name: String, icons: [String]) {
            self.name = name
            self.icons = icons
        }
    }

    public static let families: [Family] = [
        Family(name: "Money", icons: [
            "banknote.fill", "dollarsign.circle.fill", "creditcard.fill", "building.columns.fill",
            "wallet.pass.fill", "chart.line.uptrend.xyaxis", "chart.pie.fill", "bitcoinsign.circle.fill",
            "percent", "arrow.left.arrow.right", "arrow.uturn.left.circle.fill", "banknote"
        ]),
        Family(name: "Home & Bills", icons: [
            "house.fill", "bed.double.fill", "lightbulb.fill", "bolt.fill", "drop.fill", "flame.fill",
            "wifi", "phone.fill", "tv.fill", "wrench.and.screwdriver.fill", "shippingbox.fill", "key.fill"
        ]),
        Family(name: "Food & Drink", icons: [
            "cart.fill", "fork.knife", "cup.and.saucer.fill", "takeoutbag.and.cup.and.straw.fill",
            "birthday.cake.fill", "carrot.fill", "wineglass.fill", "waterbottle.fill"
        ]),
        Family(name: "Transport", icons: [
            "car.fill", "fuelpump.fill", "bus.fill", "tram.fill", "bicycle", "scooter",
            "airplane", "ferry.fill", "parkingsign.circle.fill", "road.lanes"
        ]),
        Family(name: "Shopping", icons: [
            "bag.fill", "tshirt.fill", "handbag.fill", "gift.fill", "tag.fill", "giftcard.fill",
            "sparkles", "eyeglasses"
        ]),
        Family(name: "Health & Fitness", icons: [
            "heart.fill", "cross.case.fill", "pills.fill", "stethoscope", "figure.run",
            "dumbbell.fill", "leaf.fill", "bandage.fill"
        ]),
        Family(name: "Leisure", icons: [
            "gamecontroller.fill", "film.fill", "music.note", "book.fill", "ticket.fill",
            "camera.fill", "paintbrush.fill", "guitars.fill", "popcorn.fill"
        ]),
        Family(name: "Work & Study", icons: [
            "briefcase.fill", "graduationcap.fill", "building.2.fill", "laptopcomputer",
            "doc.text.fill", "pencil", "envelope.fill", "printer.fill"
        ]),
        Family(name: "People & Pets", icons: [
            "person.fill", "person.2.fill", "figure.2.and.child.holdinghands", "pawprint.fill",
            "hand.raised.fill", "heart.text.square.fill"
        ]),
        Family(name: "Travel", icons: [
            "airplane.departure", "globe", "map.fill", "suitcase.fill", "beach.umbrella.fill",
            "tent.fill", "mountain.2.fill", "binoculars.fill"
        ]),
        Family(name: "Other", icons: [
            "star.fill", "flag.fill", "bell.fill", "bookmark.fill", "circle.grid.2x2.fill",
            "ellipsis.circle.fill", "questionmark.circle.fill", "exclamationmark.triangle.fill"
        ])
    ]

    /// Every icon in the catalogue, flattened — used to decide whether a
    /// stored icon is one the grid can highlight, or one that predates this
    /// list and needs surfacing on its own (see `IconCatalogView`).
    public static let allIcons: Set<String> = Set(families.flatMap(\.icons))
}
