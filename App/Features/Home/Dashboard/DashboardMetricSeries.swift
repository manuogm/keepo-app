import Foundation
import GRDB
import KeepoCore

/// Everything that identifies a series, minus which buckets of it are
/// wanted. Two requests differing only in window share every cached bucket
/// they overlap on, which is the whole point — scrolling a chart one month
/// re-reads one month.
struct MetricSeriesRequest: Hashable, Sendable {
    var metric: MetricKind
    let granularity: MetricGranularity
    let scope: PublicSchema.AccountScope
    let baseCurrency: String
    /// FX only — the currency being priced in the base currency.
    var quoteCurrency: String?
    /// The app's refresh token. Part of the identity rather than checked
    /// alongside it: a write anywhere bumps the token, every key minted
    /// afterwards is a different key, and nothing stale can be returned by
    /// construction.
    let token: Int

    /// The same request asking a different question. How one read files the
    /// siblings it computed along the way — see `DashboardMetricSeries.load`.
    func asking(_ metric: MetricKind) -> MetricSeriesRequest {
        var copy = self
        copy.metric = metric
        return copy
    }
}

/// One bucket of one series, loaded on demand and remembered.
///
/// The reason this exists at all: a single net-worth point recomputes every
/// account's balance and converts it, which is the most expensive read the
/// dashboard does. The expanded widgets are scrollable, zoomable and
/// offer "all time", so a naive implementation re-does that work for every
/// bucket on every frame of a scroll. Two things stop it — the caller only
/// ever asks for a window (`SeriesWindow`), and everything already computed
/// inside the current refresh token is answered from memory.
///
/// Deliberately **not** a table in the GRDB store. A persisted rollup would
/// need invalidating on every transaction write, and getting that wrong
/// means showing a stale balance — the one class of bug this app can least
/// afford. In-memory keyed on the refresh token is correct by construction:
/// a write bumps the token, and the old entries become unreachable rather
/// than wrong. If measurement ever says this isn't fast enough, the
/// persisted version drops in behind `load(_:buckets:...)` without any
/// widget changing.
actor MetricSeriesCache {
    static let shared = MetricSeriesCache()

    private struct Key: Hashable {
        let request: MetricSeriesRequest
        let bucket: Date
    }

    /// Bounded so a long session can't grow this without limit. Roughly a
    /// few hundred buckets across every widget and every zoom level, which
    /// is far more than a dashboard can show at once; past it the whole
    /// cache is dropped rather than evicted one at a time, since a wipe
    /// costs one re-read of what is on screen and an LRU costs bookkeeping
    /// on every hit.
    private static let capacity = 4_000

    private var entries: [Key: MetricPoint] = [:]

    func cached(_ request: MetricSeriesRequest, buckets: [Date]) -> [Date: MetricPoint] {
        var found: [Date: MetricPoint] = [:]
        for bucket in buckets {
            if let point = entries[Key(request: request, bucket: bucket)] {
                found[bucket] = point
            }
        }
        return found
    }

    func store(_ points: [MetricPoint], for request: MetricSeriesRequest) {
        if entries.count > Self.capacity { entries.removeAll(keepingCapacity: true) }
        for point in points {
            entries[Key(request: request, bucket: point.bucket)] = point
        }
    }
}

/// The dashboard's one series loader.
///
/// Every charting widget reads through here, which is what makes them agree:
/// one definition of where a bucket starts, one date each bucket is
/// evaluated at, one rule for what an unresolvable bucket produces (no
/// point, never a zero — money rule 5). A widget that computed its own
/// months would be free to disagree with the one beside it about what
/// "March" means.
///
/// Nothing here does FX arithmetic or re-derives a balance: every figure
/// comes from an L4 primitive (`LocalMoneyConversion.netWorth`,
/// `LocalDashboardQueries.investedTotal`/`cashflow`/`fxTrend`), same rule
/// `LocalDashboardQueries`' own header sets out.
enum DashboardMetricSeries {
    /// Loads every bucket in `window`, answering from the cache where it can.
    ///
    /// A read may compute more than it was asked for — Cashflow's money in,
    /// money out and net all fall out of one query per bucket, and the widget
    /// draws all three at once. Everything computed is filed under its own
    /// request, so the two follow-up calls are pure cache hits rather than
    /// two more passes over the same transactions.
    static func load(
        dbQueue: DatabaseQueue, request: MetricSeriesRequest, window: SeriesWindow, now: Date = Date()
    ) async throws -> [MetricPoint] {
        let granularity = window.granularity
        let buckets = granularity.buckets(from: window.from, through: window.through, calendar: utcCalendar)
        guard !buckets.isEmpty else { return [] }

        let cached = await MetricSeriesCache.shared.cached(request, buckets: buckets)
        let missing = buckets.filter { cached[$0] == nil }
        guard !missing.isEmpty else { return buckets.compactMap { cached[$0] } }

        let moneyScope = LocalMoneyScope(scope: request.scope, baseCurrency: request.baseCurrency)
        let loaded: [MetricKind: [MetricPoint]] = try await dbQueue.read { database in
            try points(database, moneyScope, request: request, buckets: missing, now: now)
        }
        for (metric, metricPoints) in loaded {
            await MetricSeriesCache.shared.store(metricPoints, for: request.asking(metric))
        }

        var byBucket = cached
        for point in loaded[request.metric] ?? [] { byBucket[point.bucket] = point }
        return buckets.compactMap { byBucket[$0] }
    }

    /// The span the user's data actually covers — what "all time" means, and
    /// what bounds a window's padding so scrolling can't wander into years
    /// that have nothing in them.
    static func availableSpan(
        dbQueue: DatabaseQueue, scope: PublicSchema.AccountScope, now: Date = Date()
    ) async throws -> DateInterval? {
        try await dbQueue.read { database in
            guard let earliest = try LocalDashboardQueries.earliestActivity(database, scope: scope) else {
                return nil
            }
            return DateInterval(start: min(earliest, now), end: now)
        }
    }

    // MARK: - Per-metric

    /// Keyed by metric because one pass can answer several — see `flows`.
    /// Every other branch returns the single entry it was asked for.
    private static func points(
        _ database: Database, _ moneyScope: LocalMoneyScope,
        request: MetricSeriesRequest, buckets: [Date], now: Date
    ) throws -> [MetricKind: [MetricPoint]] {
        let asOf = { asOfString($0, granularity: request.granularity, now: now) }
        switch request.metric {
        case .netWorth:
            return [.netWorth: try balances(database, moneyScope, buckets: buckets, asOf: asOf) {
                try LocalMoneyConversion.netWorth($0, $1, asOf: $2, now: now)
            }]
        case .invested:
            return [.invested: try balances(database, moneyScope, buckets: buckets, asOf: asOf) {
                try LocalDashboardQueries.investedTotal($0, $1, asOf: $2, now: now)
            }]
        case .investingRatio:
            return [.investingRatio: try ratios(database, moneyScope, request: request, buckets: buckets, now: now)]
        case .cashflowNet, .moneyIn, .moneyOut:
            return try flows(database, moneyScope, granularity: request.granularity, buckets: buckets, now: now)
        case .fxRate:
            return [.fxRate: try rates(database, request: request, buckets: buckets, now: now)]
        }
    }

    /// A balance metric: one reading at the end of each bucket, clamped to
    /// today for the bucket that hasn't finished.
    private static func balances(
        _ database: Database, _ moneyScope: LocalMoneyScope,
        buckets: [Date], asOf: (Date) -> String,
        _ read: (Database, LocalMoneyScope, String) throws -> Int64?
    ) throws -> [MetricPoint] {
        try buckets.map { bucket in
            MetricPoint(bucket: bucket, amountE4: try read(database, moneyScope, asOf(bucket)))
        }
    }

    /// Invested over net worth, per bucket.
    ///
    /// Computed here rather than by dividing two loaded series, because a
    /// bucket where either side is missing has to produce *no point* — a
    /// ratio from half an answer is a number that looks computed and isn't.
    /// A non-positive net worth is the same case: the ratio flips sign
    /// against a negative denominator and is undefined against zero.
    private static func ratios(
        _ database: Database, _ moneyScope: LocalMoneyScope,
        request: MetricSeriesRequest, buckets: [Date], now: Date
    ) throws -> [MetricPoint] {
        try buckets.map { bucket in
            let asOf = asOfString(bucket, granularity: request.granularity, now: now)
            guard let invested = try LocalDashboardQueries.investedTotal(database, moneyScope, asOf: asOf, now: now),
                  let netWorth = try LocalMoneyConversion.netWorth(database, moneyScope, asOf: asOf, now: now),
                  netWorth > 0
            else { return MetricPoint(bucket: bucket, value: nil) }
            return MetricPoint(
                bucket: bucket, value: Double(invested) / Double(netWorth),
                amountE4: invested, denominatorE4: netWorth
            )
        }
    }

    /// What moved *during* each bucket — all three flow metrics at once.
    ///
    /// One `cashflow` call per bucket answers money in, money out and the net
    /// together, so returning only the one asked for would mean the Cashflow
    /// widget — which plots all three on the same axis — scanned the same
    /// transactions three times. The two it did not ask for go into the cache
    /// under their own requests and are already there when it does.
    private static func flows(
        _ database: Database, _ moneyScope: LocalMoneyScope,
        granularity: MetricGranularity, buckets: [Date], now: Date
    ) throws -> [MetricKind: [MetricPoint]] {
        var net: [MetricPoint] = []
        var moneyIn: [MetricPoint] = []
        var moneyOut: [MetricPoint] = []
        for bucket in buckets {
            let totals = try LocalDashboardQueries.cashflow(
                database, moneyScope, period: bucketRange(bucket, granularity: granularity, now: now)
            )
            net.append(MetricPoint(bucket: bucket, amountE4: totals.netE4))
            moneyIn.append(MetricPoint(bucket: bucket, amountE4: totals.moneyInE4))
            moneyOut.append(MetricPoint(bucket: bucket, amountE4: totals.moneyOutE4))
        }
        return [.cashflowNet: net, .moneyIn: moneyIn, .moneyOut: moneyOut]
    }

    /// An FX rate, averaged over each bucket.
    ///
    /// One `fxTrend` call across the whole window, then grouped — not one
    /// call per bucket. Both produce the same numbers; the per-bucket
    /// version walks the same days repeatedly and was measurably the slower
    /// of the two on a year of history.
    ///
    /// Days with no published rate are absent rather than zero, so the
    /// average is over the days that actually have one. A bucket with no
    /// rates at all yields no point.
    private static func rates(
        _ database: Database, request: MetricSeriesRequest, buckets: [Date], now: Date
    ) throws -> [MetricPoint] {
        guard let quote = request.quoteCurrency, let first = buckets.first, let last = buckets.last else {
            return buckets.map { MetricPoint(bucket: $0, value: nil) }
        }
        let through = bucketRange(last, granularity: request.granularity, now: now).upperBound
        let daily = try LocalDashboardQueries.fxTrend(
            database, currency: quote, baseCurrency: request.baseCurrency, from: first, through: through
        )

        var sums: [Date: (total: Int64, days: Int)] = [:]
        for point in daily {
            let bucket = request.granularity.bucketStart(for: point.date, calendar: utcCalendar)
            let running = sums[bucket] ?? (total: 0, days: 0)
            sums[bucket] = (total: running.total + point.value, days: running.days + 1)
        }

        return buckets.map { bucket in
            guard let running = sums[bucket], running.days > 0 else {
                return MetricPoint(bucket: bucket, value: nil)
            }
            let average = Double(running.total) / Double(running.days)
            return MetricPoint(bucket: bucket, value: average / 10_000, amountE4: Int64(average.rounded()))
        }
    }

    // MARK: - Bucket bounds

    private static func asOfString(_ bucket: Date, granularity: MetricGranularity, now: Date) -> String {
        PostgresDate.dateOnlyString(
            granularity.evaluationDate(forBucket: bucket, now: now, calendar: utcCalendar), calendar: utcCalendar
        )
    }

    /// A flow bucket's days: its own start through its end, with the open
    /// bucket stopping at today rather than running into the future.
    private static func bucketRange(
        _ bucket: Date, granularity: MetricGranularity, now: Date
    ) -> ClosedRange<Date> {
        let start = granularity.bucketStart(for: bucket, calendar: utcCalendar)
        let end = granularity.evaluationDate(forBucket: bucket, now: now, calendar: utcCalendar)
        return start ... max(start, end)
    }
}
