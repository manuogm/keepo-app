import Foundation
import KeepoCore
import Testing
@testable import Keepo

/// The Net Worth widget's derivations — the rules that decide whether a
/// figure, a trend, or a chart is honest enough to draw.
@Suite("Dashboard data")
struct DashboardDataTests {
    private func metrics(
        current: Int64?, previous: Int64?, values: [Int64]
    ) -> NetWorthMetrics {
        let start = Date(timeIntervalSince1970: 0)
        return NetWorthMetrics(
            current: current, previousMonth: previous,
            series: values.enumerated().map {
                DashboardSeriesPoint(
                    date: start.addingTimeInterval(Double($0.offset) * 86_400), value: $0.element
                )
            }
        )
    }

    @Test("Two points are not a trajectory — a single straight segment says nothing a badge doesn't")
    func twoPointsIsNotATrajectory() {
        #expect(metrics(current: 100, previous: 90, values: [10, 20]).hasTrajectory == false)
        #expect(metrics(current: 100, previous: 90, values: [10, 20, 30]).hasTrajectory)
    }

    @Test("An unchanging series is the flat line the widget must never draw")
    func flatSeriesIsNotATrajectory() {
        #expect(metrics(current: 100, previous: 90, values: [50, 50, 50, 50]).hasTrajectory == false)
    }

    @Test("An empty series has no trajectory")
    func emptySeriesIsNotATrajectory() {
        #expect(metrics(current: 100, previous: 90, values: []).hasTrajectory == false)
    }

    /// Money rule 5 — an unresolvable side propagates to "—", never to a
    /// percentage that looks computed.
    @Test("A missing figure on either side leaves the trend uncomputable")
    func missingSideLeavesTrendNil() {
        #expect(metrics(current: nil, previous: 90, values: []).percentChange == nil)
        #expect(metrics(current: 100, previous: nil, values: []).percentChange == nil)
    }

    @Test("A zero baseline has no percentage, rather than an infinite one")
    func zeroBaselineHasNoPercentage() {
        #expect(metrics(current: 100, previous: 0, values: []).percentChange == nil)
    }

    @Test("Percent change is signed off the previous figure's magnitude")
    func percentChangeIsComputedFromMagnitude() {
        #expect(metrics(current: 150, previous: 100, values: []).percentChange == 50)
        #expect(metrics(current: 50, previous: 100, values: []).percentChange == -50)
        // A net worth climbing out of debt reads as a gain, not a loss —
        // dividing by the signed value would flip the sign here.
        #expect(metrics(current: -50, previous: -100, values: []).percentChange == 50)
    }

    @Test("Trend colour never makes an uncomputable change look like good news")
    func uncomputableTrendIsNeverGreen() {
        #expect(DashboardTrend.color(for: nil) == .secondary)
        #expect(DashboardTrend.color(for: 1) == .green)
        #expect(DashboardTrend.color(for: -1) == .red)
    }
}
