import Foundation

/// An account's icon and color are purely presentational, same as a
/// category's (`CategoryAppearance`) — the default-by-subtype heuristic and
/// curated icon set live here, one place, used both when a new account is
/// created and whenever the picker needs its options. Color reuses
/// `CategoryAppearance.randomColor()` directly rather than duplicating the
/// palette — nothing about it is category-specific.
public enum AccountAppearance {
    public static func defaultIcon(forSubtype subtype: PublicSchema.AccountSubtype) -> String {
        switch subtype {
        case .checking: return "banknote"
        case .cash: return "dollarsign.circle"
        case .creditCard: return "creditcard"
        case .loan: return "building.columns"
        case .investment: return "chart.line.uptrend.xyaxis"
        }
    }

    /// The picker's full menu — the subtype defaults plus a handful of
    /// generic extras, so a user picking a different icon isn't limited to
    /// whatever the heuristic already knows about.
    public static let pickerIcons: [String] = {
        let candidates = [
            "banknote", "dollarsign.circle", "creditcard", "building.columns", "chart.line.uptrend.xyaxis",
            "wallet.pass", "house.fill", "car.fill", "airplane", "gift.fill", "star.fill",
            "wrench.and.screwdriver.fill", "briefcase.fill", "graduationcap.fill"
        ]
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }()
}
