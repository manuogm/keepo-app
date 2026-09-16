import Foundation
import Testing
@testable import KeepoCore

/// The user picks a set; this picks the arrangement. What is pinned here is
/// the property that matters — **no gap above the last row** — plus the
/// specific ordering rules agreed for how the grid should read.
@Suite("Onboarding dashboard plan")
struct OnboardingDashboardPlanTests {
    private let wides: [DashboardWidgetKind] = [.netWorth, .cashflow, .upcomingBills]
    private let smalls: [DashboardWidgetKind] = [.investingRatio, .currencyExposure, .fxRate]

    /// Walks the grid the way `DashboardArrangement` will and reports the
    /// row index of every gap. A gap anywhere but the final row is the bug
    /// this whole type exists to prevent.
    private func gapRows(_ order: [DashboardWidgetKind]) -> [Int] {
        var row = 0
        var column = 0
        var gaps: [Int] = []
        for kind in order {
            let width = kind.baseSize.columns
            if column + width > DashboardLayout.columnCount {
                gaps.append(row)
                row += 1
                column = 0
            }
            column += width
            if column >= DashboardLayout.columnCount {
                row += 1
                column = 0
            }
        }
        if column > 0 { gaps.append(row) }
        return gaps
    }

    @Test("every selection packs with no gap except possibly the last row")
    func noGapsExceptTheLastRow() {
        let all = wides + smalls
        // All 64 subsets. Six widgets is small enough to simply prove it.
        for mask in 0..<(1 << all.count) {
            let selection = all.indices.filter { mask & (1 << $0) != 0 }.map { all[$0] }
            let order = OnboardingDashboardPlan.arrange(selection)
            #expect(Set(order) == Set(selection), "arrange must neither drop nor invent a widget")

            let gaps = gapRows(order)
            let rows = gaps.last.map { $0 + 1 } ?? 0
            for gap in gaps {
                #expect(gap == rows - 1, "gap in row \(gap) of \(rows) for \(selection)")
            }
            #expect(gaps.count <= 1, "at most one gap, for \(selection)")
        }
    }

    @Test("an odd half-width widget is always last")
    func oddOneGoesLast() {
        let order = OnboardingDashboardPlan.arrange([.netWorth, .investingRatio, .currencyExposure, .fxRate])
        #expect(order.count == 4)
        #expect(order.last?.baseSize.columns == 1)
    }

    @Test("Net Worth leads whenever it is chosen")
    func netWorthLeads() {
        #expect(OnboardingDashboardPlan.arrange([.fxRate, .cashflow, .netWorth]).first == .netWorth)
        #expect(OnboardingDashboardPlan.arrange([.investingRatio, .netWorth]).first == .netWorth)
    }

    /// Opening on a half-width tile means opening on a visible gap beside
    /// it, so a full-width widget leads when Net Worth is not chosen.
    @Test("a full-width widget leads when Net Worth is not chosen")
    func fullWidthLeadsOtherwise() {
        let order = OnboardingDashboardPlan.arrange([.fxRate, .cashflow])
        #expect(order.first == .cashflow)
    }

    @Test("with no full-width widget at all the halves simply lead")
    func halvesLeadWhenNothingElseCan() {
        let order = OnboardingDashboardPlan.arrange([.currencyExposure, .fxRate])
        #expect(order == [.currencyExposure, .fxRate])
        #expect(OnboardingDashboardPlan.arrange([.investingRatio]) == [.investingRatio])
    }

    /// Two widgets answering halves of the same question should land in one
    /// row when both are chosen, rather than being split by the mechanical
    /// pairing that would otherwise take Investing Ratio first.
    @Test("Currency Exposure and FX Rate sit side by side when both are chosen")
    func affinityPairsStayTogether() {
        let order = OnboardingDashboardPlan.arrange(smalls)
        let exposure = try? #require(order.firstIndex(of: .currencyExposure))
        let rate = try? #require(order.firstIndex(of: .fxRate))
        #expect(exposure != nil && rate != nil)
        if let exposure, let rate {
            #expect(abs(exposure - rate) == 1, "the pair must be adjacent: \(order)")
        }
        // And the one left over is the odd widget at the bottom.
        #expect(order.last == .investingRatio)
    }

    @Test("the same set always produces the same order, whatever order it arrives in")
    func arrangementIsStable() {
        let forwards = OnboardingDashboardPlan.arrange([.netWorth, .cashflow, .fxRate])
        let backwards = OnboardingDashboardPlan.arrange([.fxRate, .cashflow, .netWorth])
        #expect(forwards == backwards)
    }

    @Test("an empty selection arranges to nothing")
    func emptyIsEmpty() {
        #expect(OnboardingDashboardPlan.arrange([]).isEmpty)
    }
}
