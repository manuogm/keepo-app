import Foundation

/// An account's icon and color are purely presentational, same as a
/// category's (`CategoryAppearance`). This owns only the default-by-kind
/// heuristic — the menu a user picks something else from lives in
/// `IconLibrary`, shared with categories so the two can never drift into
/// separate lists. Color reuses `CategoryAppearance.randomColor()` directly
/// rather than duplicating the palette — nothing about it is
/// category-specific.
public enum AccountAppearance {
    public static func defaultIcon(forKind kind: PublicSchema.AccountKind) -> String {
        switch kind {
        case .regular: return "banknote.fill"
        case .investment: return "chart.line.uptrend.xyaxis"
        }
    }
}
