import Foundation
import GRDB
import KeepoCore
import SwiftUI

/// Everything a charting widget has to keep track of, in one place: what it
/// is measuring, at what resolution, which slice of time is on screen, which
/// bucket is highlighted, and how much of the series has actually been
/// loaded.
///
/// Shared rather than repeated per widget because these pieces only work as
/// a set. The resolution decides the buckets; the buckets decide what
/// "visible" means; visible decides which window to load; the highlighted
/// bucket decides what the headline reads. Four widgets each wiring that up
/// would be four chances to get the same interaction subtly different — and
/// the user's requirement is the opposite of that.
///
/// **The bucket domain is the whole timeline, not the loaded window.** That
/// separation is what makes scrolling work: `buckets` spans everything the
/// timeframe covers (cheap — it is only dates), so a bucket's x position
/// never moves, while `points` holds only the window that has actually been
/// computed. Scrolling reveals empty axis slots for a moment and fills them
/// in, instead of renumbering every mark under the user's finger.
@Observable
@MainActor
final class SeriesWidgetState {
    let kind: DashboardWidgetKind

    /// What the widget is set to. Resets to the kind's default whenever the
    /// widget collapses, per the design — nothing persists a config.
    var config: WidgetConfig

    /// Extra metrics drawn on the same axis as `config.metric`, loaded over
    /// the same window.
    ///
    /// Cashflow is the case this exists for: its chart is money in, money out
    /// and the net line together, and the three are computed by one pass over
    /// the same transactions (see `DashboardMetricSeries.flows`). Read from
    /// the kind rather than assigned by the view, so they are in place before
    /// the first load can run — assigned from `.onAppear` they sometimes were
    /// not, and the widget opened with both bar series missing.
    private var companions: [MetricKind] { kind.companionMetrics }

    private(set) var points: [MetricPoint] = []
    private(set) var companionPoints: [MetricKind: [MetricPoint]] = [:]
    private(set) var buckets: [Date] = []
    private(set) var availableSpan: DateInterval?
    private(set) var isLoading = false

    /// The bucket the headline is reading. `nil` only before the first load.
    var highlighted: Date?
    /// How many buckets fit on screen. Set by the timeframe segments and by
    /// nothing else — the chart only reads it.
    ///
    /// It used to be shared with a pinch gesture that could *derive* a
    /// granularity from the count, which needed a flag to stop the two
    /// undoing each other: tapping "W" set weekly and the derivation
    /// immediately coarsened it straight back to monthly, so the segment
    /// looked dead. With the pinch gone the granularity has exactly one
    /// source, and the flag has nothing left to arbitrate.
    var visibleBuckets: Int = 12
    /// Leading edge of the visible window, in bucket indices.
    var scrollIndex: Double = 0

    private var loadedWindow: SeriesWindow?
    /// The granularity the last load ran at, so a zoom that crosses a
    /// threshold is noticed exactly once.
    private var loadedGranularity: MetricGranularity?

    init(kind: DashboardWidgetKind) {
        self.kind = kind
        self.config = kind.defaultConfig
    }

    var granularity: MetricGranularity {
        config.granularity(availableSpan: availableSpan, calendar: utcCalendar)
    }

    /// The highlighted bucket's point, which is what the headline and the
    /// trend badge both read.
    var highlightedPoint: MetricPoint? {
        guard let highlighted else { return points.last }
        return points.first { $0.bucket == highlighted }
    }

    /// The bucket immediately before the highlighted one — the trend badge's
    /// baseline. Taken from the series rather than recomputed, so the badge
    /// can only ever compare two figures the chart is actually drawing.
    var previousPoint: MetricPoint? {
        guard let current = highlightedPoint,
              let index = points.firstIndex(where: { $0.bucket == current.bucket }), index > 0
        else { return nil }
        return points[index - 1]
    }

    /// Period-over-period change, as a percentage of the baseline.
    var percentChange: Double? {
        guard let current = highlightedPoint?.value, let previous = previousPoint?.value, previous != 0 else {
            return nil
        }
        return (current - previous) / abs(previous) * 100
    }

    /// The same change in **percentage points**, for a metric that is
    /// already a percentage. Going from 30% to 33% is "+3 pts"; calling that
    /// "+10%" would be true of the ratio and useless to the reader.
    var pointChange: Double? {
        guard let current = highlightedPoint?.value, let previous = previousPoint?.value else { return nil }
        return (current - previous) * 100
    }

    /// The movement across the whole loaded series, first plottable point to
    /// last — which is what the **chart's colour** means.
    ///
    /// Deliberately not `percentChange`, which is the highlighted bucket
    /// against its predecessor. Colouring the line by that greyed the entire
    /// chart the moment the user highlighted its earliest bucket, because
    /// there is nothing before it to compare against — the trajectory had
    /// not changed at all, only the question being asked about one point on
    /// it. The badge answers that question; the line answers "which way has
    /// this gone over the stretch I am looking at".
    var overallChange: Double? {
        let values = points.compactMap(\.value)
        guard let first = values.first, let last = values.last, first != 0 else { return nil }
        return (last - first) / abs(first) * 100
    }

    /// Whether the widget is looking at a bucket other than the newest one —
    /// which is what switches the badge's caption from "vs last month" to
    /// the explicit "vs previous month".
    var isHighlightingPast: Bool {
        guard let highlighted, let latest = buckets.last else { return false }
        return highlighted != latest
    }

    // MARK: - Loading

    struct Context {
        let dbQueue: DatabaseQueue
        let scope: PublicSchema.AccountScope
        let baseCurrency: String
        let token: Int
        let now: Date

        init(
            dbQueue: DatabaseQueue, scope: PublicSchema.AccountScope,
            baseCurrency: String, token: Int, now: Date = Date()
        ) {
            self.dbQueue = dbQueue
            self.scope = scope
            self.baseCurrency = baseCurrency
            self.token = token
            self.now = now
        }
    }

    /// Brings the state in line with whatever the user just did — changed
    /// the timeframe, pinched, scrolled, or opened the widget for the first
    /// time. Safe to call repeatedly: it reads nothing it already has.
    func refresh(_ context: Context) async {
        if availableSpan == nil {
            availableSpan = try? await DashboardMetricSeries.availableSpan(
                dbQueue: context.dbQueue, scope: context.scope, now: context.now
            )
        }
        rebuildBuckets(now: context.now)
        guard !buckets.isEmpty else {
            points = []
            return
        }
        await loadVisibleWindow(context)
    }

    /// Fills the state from fixed sample data, for the catalogue.
    ///
    /// A charting widget loads through a database context, and the
    /// catalogue deliberately has none — its entries must cost no reads.
    /// Without this the FX tile in the picker rendered its own "add another
    /// currency" empty state, which is precisely the wrong promise: the
    /// widget was available, and the picture beside it said it wasn't.
    func showPreview(_ preview: [MetricPoint]) {
        guard points.isEmpty else { return }
        points = preview
        buckets = preview.map(\.bucket)
        highlighted = buckets.last
        visibleBuckets = min(12, max(buckets.count, 1))
        scrollIndex = max(Double(buckets.count - visibleBuckets), 0)
    }

    /// Collapsing throws away everything the user chose. Deliberate, and the
    /// user's own call: a widget always opens in a known state rather than
    /// wherever it was left days ago.
    func reset() {
        config = kind.defaultConfig
        highlighted = nil
        visibleBuckets = 12
        scrollIndex = 0
        loadedWindow = nil
        loadedGranularity = nil
        points = []
        companionPoints = [:]
        buckets = []
    }

    /// One companion metric's points, or an empty series before it loads.
    func series(_ metric: MetricKind) -> [MetricPoint] {
        metric == config.metric ? points : (companionPoints[metric] ?? [])
    }

    /// The user picked a segment (or a custom period). An explicit choice
    /// always wins: the bucket count is reset to a comfortable default for
    /// the new resolution rather than carried over from the old one, where
    /// it would mean a completely different span of time.
    func select(_ timeframe: MetricTimeframe) {
        config.timeframe = timeframe
        if case .rolling(let granularity) = timeframe {
            visibleBuckets = Self.defaultVisibleBuckets(for: granularity)
        }
    }

    /// How much history a resolution opens on: two months of weeks, a year
    /// of months, half a decade of years. Enough of each to have a shape
    /// without the bars getting too thin to aim at.
    private static func defaultVisibleBuckets(for granularity: MetricGranularity) -> Int {
        switch granularity {
        case .week: return 8
        case .month: return 12
        case .year: return 6
        }
    }

    /// The x domain: every bucket the current timeframe covers. Rebuilt from
    /// scratch each refresh because it is only dates — and cheap enough that
    /// caching it would be more bookkeeping than it saves.
    private func rebuildBuckets(now: Date) {
        let granularity = granularity
        let domain = domainRange(now: now)
        let previousCount = buckets.count
        buckets = granularity.buckets(from: domain.lowerBound, through: domain.upperBound, calendar: utcCalendar)
        guard !buckets.isEmpty else { return }
        // First render, or a resolution change that renumbered everything:
        // park at the right-hand end, where "now" is. The design asks for
        // the current period at the far right, and it is also the only
        // position that is meaningful before the user has scrolled.
        if previousCount != buckets.count {
            scrollIndex = max(Double(buckets.count - visibleBuckets), 0)
        }
        if loadedGranularity != granularity {
            loadedWindow = nil
            loadedGranularity = granularity
        }
        // Settled here, beside the domain it is an index into, rather than
        // after the load it does not depend on. It reads `buckets` and
        // nothing else, and running it afterwards made it a *separate*
        // publish landing in its own render — so the chart drew once with
        // every bar dimmed and again with one of them lit.
        if highlighted == nil || !buckets.contains(highlighted ?? .distantPast) {
            highlighted = defaultHighlight
        }
    }

    private func domainRange(now: Date) -> ClosedRange<Date> {
        let earliest = availableSpan?.start ?? utcCalendar.date(byAdding: .year, value: -1, to: now) ?? now
        switch config.timeframe {
        case .rolling, .allTime:
            return min(earliest, now) ... now
        case .custom(let range):
            return range.lowerBound ... min(range.upperBound, now)
        }
    }

    /// Loads the window around what is on screen, and only if what is
    /// already loaded doesn't cover it.
    private func loadVisibleWindow(_ context: Context) async {
        let lower = max(Int(scrollIndex.rounded(.down)), 0)
        let upper = min(lower + max(visibleBuckets, 1) - 1, buckets.count - 1)
        guard lower <= upper else { return }
        let visibleFrom = buckets[lower]
        let visibleThrough = buckets[upper]

        if let loadedWindow,
           loadedWindow.covers(visibleFrom: visibleFrom, visibleThrough: visibleThrough, granularity: granularity) {
            return
        }

        let window = SeriesWindow.covering(
            visibleFrom: visibleFrom, visibleThrough: visibleThrough, granularity: granularity,
            limit: buckets.first.map { $0 ... (buckets.last ?? $0) }, calendar: utcCalendar
        )
        let request = MetricSeriesRequest(
            metric: config.metric, granularity: granularity, scope: context.scope,
            baseCurrency: context.baseCurrency, quoteCurrency: config.quoteCurrency, token: context.token
        )

        isLoading = true
        defer { isLoading = false }
        guard let loaded = try? await DashboardMetricSeries.load(
            dbQueue: context.dbQueue, request: request, window: window, now: context.now
        ) else { return }
        // Gathered into locals, **assigned in one go below**.
        //
        // These are cache hits after the primary load — the pass that
        // produced it computed them too — but they are still `await`ed, and
        // an `await` is a suspension point. Assigning each one as it arrived
        // published it on its own, and Cashflow drew three times on every
        // load: the net line alone, then one bar series, then both. That is
        // the flicker on expanding the widget.
        //
        // Loaded through the same path rather than reached for out of the
        // cache directly, so a metric that is *not* a by-product of the
        // primary read still works without a special case.
        var loadedCompanions: [MetricKind: [MetricPoint]] = [:]
        for metric in companions {
            loadedCompanions[metric] = (try? await DashboardMetricSeries.load(
                dbQueue: context.dbQueue, request: request.asking(metric), window: window, now: context.now
            )) ?? []
        }
        // No `await` between these, so SwiftUI sees one complete set and
        // renders once. Replacing `companionPoints` wholesale rather than
        // keying into it also drops anything left over from a previous
        // granularity, which keying could not.
        points = loaded
        companionPoints = loadedCompanions
        loadedWindow = window
    }

    /// Which bucket is read when the user hasn't picked one: the newest,
    /// unless it is still open *and* holds a figure that can't be fairly
    /// compared against a finished period — see
    /// `MetricKind.currentBucketIsPartial`.
    private var defaultHighlight: Date? {
        guard let latest = buckets.last else { return nil }
        guard config.metric.currentBucketIsPartial,
              granularity.isCurrent(bucket: latest, now: Date(), calendar: utcCalendar)
        else { return latest }
        return buckets.count >= 2 ? buckets[buckets.count - 2] : latest
    }
}
