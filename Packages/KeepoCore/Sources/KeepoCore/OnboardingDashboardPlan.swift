import Foundation

/// Turns "these are the widgets I want" into the order they are added to a
/// brand-new dashboard.
///
/// **The user no longer sets the order, so Keepo owes them a good one.**
/// Onboarding's dashboard step used to collect a sequence — tap order was
/// layout order — which asked someone who has never seen the dashboard to
/// make a decision about it, and produced a gap in the grid whenever their
/// sequence happened to strand a half-width widget. Now they choose a set
/// and this decides the arrangement.
///
/// **There is exactly one way a gap can happen.** The grid is two columns
/// and `DashboardTile.size` is computed from the widget kind, so a tile can
/// never be resized to fill a hole. Three widgets are half-width
/// (`.investingRatio`, `.currencyExposure`, `.fxRate`) and three are full
/// width; full-width tiles always take a whole row, and half-width tiles
/// pair. So the grid is gapless unless an **odd number of half-width
/// widgets** is chosen, and the single rule that follows is: put the odd
/// one last, where its empty neighbour is the bottom edge of the grid and
/// reads as room for another widget rather than as a hole.
///
/// Everything else here is about rhythm rather than correctness:
///
///  1. Net Worth leads when it is chosen — it is the app's headline figure
///     and the first thing anyone looks for.
///  2. Otherwise a full-width widget leads, because a dashboard that opens
///     on a half-width tile opens on a visible gap beside it.
///  3. With no full-width widget at all, a pair of half-width ones leads
///     (or the single one, if that is all there is).
///  4. Then pairs and full-width widgets alternate, so a dense two-up row
///     is always followed by a wide one instead of the grid arriving as
///     three small rows and then three big ones.
public enum OnboardingDashboardPlan {
    /// Half-width widgets that belong **side by side** when both are
    /// chosen. Currency Exposure and FX Rate answer two halves of the same
    /// question — what you hold, and what it is worth today — and a user
    /// who picks both is telling us they care about that question. Put in a
    /// row together they read as one block; split across the grid by a
    /// mechanical pairing they read as two unrelated tiles.
    static let affinities: [[DashboardWidgetKind]] = [
        [.currencyExposure, .fxRate]
    ]

    public static func arrange(_ selected: [DashboardWidgetKind]) -> [DashboardWidgetKind] {
        // Catalogue order, not the order they were tapped in: the tap order
        // is no longer meaningful and letting it leak through would make
        // the same set of choices produce different dashboards.
        let ordered = DashboardWidgetKind.allCases.filter(selected.contains)
        var wides = ordered.filter { $0.baseSize.columns >= DashboardLayout.columnCount }
        let smalls = ordered.filter { $0.baseSize.columns < DashboardLayout.columnCount }
        var (pairs, leftover) = pairUp(smalls)

        var result: [DashboardWidgetKind] = []

        if let netWorth = wides.firstIndex(of: .netWorth) {
            result.append(wides.remove(at: netWorth))
        } else if !wides.isEmpty {
            result.append(wides.removeFirst())
        }

        while !pairs.isEmpty || !wides.isEmpty {
            if !pairs.isEmpty { result.append(contentsOf: pairs.removeFirst()) }
            if !wides.isEmpty { result.append(wides.removeFirst()) }
        }

        if let leftover { result.append(leftover) }
        return result
    }

    /// Affinity pairs first, then whatever is left two at a time. The
    /// remainder — at most one, since a pair takes two — is the widget that
    /// will sit alone at the bottom.
    private static func pairUp(
        _ smalls: [DashboardWidgetKind]
    ) -> (pairs: [[DashboardWidgetKind]], leftover: DashboardWidgetKind?) {
        var remaining = smalls
        var pairs: [[DashboardWidgetKind]] = []

        for affinity in affinities where affinity.allSatisfy(remaining.contains) {
            pairs.append(affinity)
            remaining.removeAll(where: affinity.contains)
        }
        while remaining.count >= 2 {
            pairs.append([remaining.removeFirst(), remaining.removeFirst()])
        }
        return (pairs, remaining.first)
    }
}
