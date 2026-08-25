import Foundation

/// What a widget's chart is measuring. The series pipeline takes one of
/// these plus a granularity and a window, and every charting widget on the
/// dashboard is some combination of the two — which is the point: a future
/// user-built "Hero Trendline" widget is a `MetricKind` the user picked
/// rather than a new code path.
public enum MetricKind: String, Sendable, Equatable, Codable, CaseIterable {
    /// Assets minus liabilities, at the end of each bucket.
    case netWorth
    /// The balance of accounts marked as investments, at the end of each
    /// bucket.
    case invested
    /// `invested ÷ netWorth`. Not derivable from the two above by the chart,
    /// because a bucket where either side is unresolvable has to produce no
    /// point at all rather than a ratio computed from half an answer.
    case investingRatio
    /// Money in plus money out, over each bucket. A flow, not a balance.
    case cashflowNet
    case moneyIn
    case moneyOut
    /// One unit of the quote currency in the base currency, averaged over
    /// each bucket.
    case fxRate

    /// Whether the current, still-open bucket holds a figure that **cannot
    /// be fairly compared** against a finished one — which is what decides
    /// whether a widget opens reading this period or the last closed one.
    ///
    /// The distinction is not balance-versus-flow, which is the tempting
    /// and wrong cut:
    ///
    /// - A **balance** (net worth, invested, the ratio between them) is a
    ///   reading at a moment. "As of today" is complete by definition.
    /// - A **sum over a period** (money in, money out, their net) is
    ///   genuinely partial. On the 3rd of the month, month-to-date spending
    ///   measured against a whole month reads as a collapse in spending
    ///   every time the month rolls over.
    /// - An **average over a period** (an FX rate) is a sum divided by its
    ///   own count, so it is scale-free: August's average over nineteen
    ///   days is directly comparable to July's over thirty-one.
    ///
    /// FX sat on the wrong side of this when it was first written, and the
    /// widget opened showing last month's rate while the chart's right-hand
    /// end — where the eye goes — was this month's.
    public var currentBucketIsPartial: Bool {
        switch self {
        case .cashflowNet, .moneyIn, .moneyOut: return true
        case .netWorth, .invested, .investingRatio, .fxRate: return false
        }
    }
}

/// How a series is drawn. Today each widget pins this; it is the second
/// thing a template widget will hand to the user ("show it as bars").
public enum MetricVisualization: String, Sendable, Equatable, Codable, CaseIterable {
    case line
    case bar
}

/// What the trend badge measures against. Today always the immediately
/// preceding bucket; `sameBucketLastYear` is the option the user named as
/// part of the template vision, and the badge caption is derived from this
/// rather than hardcoded so that adding it is a data change.
public enum MetricComparison: String, Sendable, Equatable, Codable, CaseIterable {
    case previousBucket
    case sameBucketLastYear
}

/// Everything about a widget that a user could one day choose.
///
/// It exists now, ahead of any editor, for one reason: it is the seam. The
/// six widgets shipping today each pin a fixed value here and never expose
/// it, so nothing in the UI depends on a config being editable — but every
/// widget already *reads* its behaviour from this struct rather than from
/// hardcoded literals scattered through its own view. When template widgets
/// arrive, the editor writes into this type and the widgets need no change.
///
/// `Codable` for the same reason, and only that reason. **Nothing persists
/// a config today** — a widget resets to its default on collapse and on
/// relaunch, per the user's explicit decision, and there is no storage
/// anywhere behind this. The conformance is one line and makes the eventual
/// per-tile storage a matter of writing it down rather than reshaping this.
public struct WidgetConfig: Sendable, Equatable, Codable {
    public var metric: MetricKind
    public var timeframe: MetricTimeframe
    public var visualization: MetricVisualization
    public var comparison: MetricComparison
    /// The FX widget's numerator — the currency being priced *in* the base
    /// currency. `nil` for every other widget, and for an FX widget that
    /// hasn't resolved a default yet.
    public var quoteCurrency: String?

    public init(
        metric: MetricKind,
        timeframe: MetricTimeframe = .default,
        visualization: MetricVisualization = .line,
        comparison: MetricComparison = .previousBucket,
        quoteCurrency: String? = nil
    ) {
        self.metric = metric
        self.timeframe = timeframe
        self.visualization = visualization
        self.comparison = comparison
        self.quoteCurrency = quoteCurrency
    }

    /// The resolution to draw at, given how much data exists.
    public func granularity(availableSpan: DateInterval?, calendar: Calendar) -> MetricGranularity {
        timeframe.granularity(availableSpan: availableSpan, calendar: calendar)
    }
}
