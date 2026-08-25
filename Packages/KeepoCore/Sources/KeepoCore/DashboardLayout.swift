import Foundation

/// The dashboard's grid model — pure logic, no SwiftUI, so every placement
/// rule below is unit-testable instead of debugged by hand in the simulator.
/// The view layer's only job is to say which cell a finger is over; every
/// decision about what that means happens here.
///
/// **Placement is absolute, not flow.** Each tile stores its own `(row,
/// column)`. A lone 1×1 sitting in the right column with an empty cell
/// beside it is a first-class arrangement the user can build deliberately
/// and keep forever — a flow model (pack in reading order) cannot express
/// it at all, which is why this isn't one.
///
/// The one thing that *does* move on its own is a **fully empty row**: it
/// collapses, and everything below shifts up. Without that, removing the
/// only tile in row 3 would leave a blank band no gesture could ever get
/// rid of. A row with one tile and one hole is not empty and is never
/// touched. (A deliberate blank band, if it's ever wanted, is a spacer
/// widget — not a special case here.)
public enum DashboardLayout {
    /// Two columns, always. `columnCount` exists so the packing rules read
    /// as rules rather than as hardcoded `1`s, not because a third column
    /// is planned — the widget size vocabulary below assumes two.
    public static let columnCount = 2

    /// **A row is half a column.** Every widget is therefore two rows tall,
    /// and `DashboardGeometry` sizes two rows to exactly one column width —
    /// so a widget occupies the same square it always did, and nothing on an
    /// existing dashboard changed size when the row split.
    ///
    /// The split exists so a tile *can* be one row tall: a spacer that opens
    /// half a widget of breathing room, which a full-height row could not
    /// express without leaving a hole the size of a widget.
    public static let rowsPerWidget = 2
}

// MARK: - Size

/// A widget's footprint, in grid cells. Named `rows`/`columns` in that
/// order because that's the order the user's own spec uses ("a 1×2 widget
/// fills 1 full row + the 2 columns").
public struct DashboardWidgetSize: Sendable, Equatable, Hashable, Codable {
    public let rows: Int
    public let columns: Int

    public init(rows: Int, columns: Int) {
        self.rows = rows
        self.columns = columns
    }

    /// The two shapes a tile rests at — both `rowsPerWidget` tall, which is
    /// what makes them square and full-width-square respectively. Expanded
    /// sizes are always full width (see `DashboardWidgetKind.expandedSizes`).
    public static let small = DashboardWidgetSize(rows: DashboardLayout.rowsPerWidget, columns: 1)
    public static let wide = DashboardWidgetSize(rows: DashboardLayout.rowsPerWidget, columns: 2)

    /// `n` widget-heights, in rows — the unit every widget size is expressed
    /// in, so no call site has to remember that a row is half a widget.
    public static func widgets(_ count: Int, columns: Int) -> DashboardWidgetSize {
        DashboardWidgetSize(rows: count * DashboardLayout.rowsPerWidget, columns: columns)
    }
}

// MARK: - Kind

/// Every widget the catalogue offers. Lives in `KeepoCore` rather than the
/// App target because it is pure data — a kind, its footprints, and its
/// name — with no view attached; the layout tests need real kinds, and
/// `DashboardStore`'s persisted JSON needs one `Codable` vocabulary rather
/// than a UI enum and a storage enum that can drift apart.
///
/// The raw values are a storage format: they are written into
/// `UserDefaults` and read back on the next launch, so renaming one
/// silently drops that widget off every existing dashboard. Add cases
/// freely; never rename one.
public enum DashboardWidgetKind: String, Sendable, CaseIterable, Codable {
    case netWorth = "net_worth"
    case investingRatio = "investing_ratio"
    case currencyExposure = "currency_exposure"
    case upcomingBills = "upcoming_bills"
    case cashflow
    case fxRate = "fx_rate"

    /// The title in the tile's header and in the catalogue. Free to change —
    /// unlike `rawValue`, which is a storage format (see above), the title
    /// is never written to disk. `upcomingBills` reads "Transactions Next 2
    /// Weeks" while still storing `upcoming_bills` for exactly that reason.
    public var title: String {
        switch self {
        case .netWorth: return "Networth Analysis"
        case .investingRatio: return "Investing Ratio"
        case .currencyExposure: return "Currency Exposure"
        case .upcomingBills: return "Transactions Next 2 Weeks"
        case .cashflow: return "Cashflow Breakdown"
        case .fxRate: return "FX Rate"
        }
    }

    /// The glyph in the tile's header and beside its catalogue entry — one
    /// value, so a widget can't be one thing on the dashboard and another in
    /// the picker the user chose it from.
    public var systemImage: String {
        switch self {
        case .netWorth: return "chart.line.uptrend.xyaxis"
        case .investingRatio: return "chart.pie"
        case .currencyExposure: return "globe"
        case .upcomingBills: return "calendar"
        case .cashflow: return "arrow.up.arrow.down"
        case .fxRate: return "arrow.left.arrow.right"
        }
    }

    /// One line for the catalogue — what this widget answers, not what it
    /// looks like; the preview beside it already shows that.
    public var summary: String {
        switch self {
        case .netWorth: return "Everything you own, minus what you owe, over time."
        case .investingRatio: return "How much of your net worth is invested."
        case .currencyExposure: return "Which currencies your money sits in."
        case .upcomingBills: return "What's coming in and going out over the next two weeks."
        case .cashflow: return "What came in against what went out, and where it went."
        case .fxRate: return "What one currency is worth in yours, over time."
        }
    }

    /// The size the tile rests at, and the size it returns to in edit mode.
    ///
    /// Sizes are raw grid `rows × columns`, and a row is **half** a column's
    /// width — so 2×1 is a square and 2×2 a full-width band. That is the
    /// vocabulary the design is written in, so it is the vocabulary here;
    /// converting between two conventions on the way in is how a widget ends
    /// up the wrong shape.
    ///
    /// Every collapsed tile is `rowsPerWidget` tall. The half-row grid still
    /// exists — the add/trash bar needs it — but no widget rests at an odd
    /// row count any more; see the note in `.upcomingBills` below.
    public var baseSize: DashboardWidgetSize {
        switch self {
        case .investingRatio, .currencyExposure, .fxRate:
            return .small
        case .netWorth, .cashflow, .upcomingBills:
            // Upcoming was the one half-height tile (1×2). At a large text
            // size its content no longer fitted the ~27pt a single row leaves
            // once the card's padding and header are taken out, so it drew
            // through the gutter and made the grid's spacing — which is a
            // uniform 12pt by construction — look tighter around this one
            // widget. Full height instead: every collapsed tile is now the
            // same height, so nothing about the spacing can depend on which
            // widget is next to it.
            return .wide
        }
    }

    /// The sizes expansion steps through, in order, after the base size.
    /// **Every expanded size is full width** — a square growing sideways
    /// only would leave its neighbour stranded beside a tall tile, which
    /// reads as a rendering bug rather than as a deliberate expansion.
    ///
    /// Every widget has exactly one. Cashflow used to have two (in/out,
    /// then a taller step for one side's categories); its 6×2 now carries
    /// the category breakdown at all times, so the intermediate step has
    /// nothing left to mean.
    public var expandedSizes: [DashboardWidgetSize] {
        switch self {
        case .cashflow:
            return [DashboardWidgetSize.widgets(3, columns: 2)]
        case .netWorth, .investingRatio, .currencyExposure, .fxRate, .upcomingBills:
            // Upcoming grew with its base size: expanding has to *add* room,
            // and one widget-height is now what it rests at.
            return [DashboardWidgetSize.widgets(2, columns: 2)]
        }
    }

    // MARK: - Configuration

    /// The resolutions this widget's timeframe filter offers, finest first.
    ///
    /// FX is the only one that goes below a month, and that is a data
    /// property rather than a design preference: a rate has a value every
    /// day, whereas a net worth or a cashflow bucketed weekly is dominated
    /// by whichever week salary landed in.
    public var allowedGranularities: [MetricGranularity] {
        switch self {
        case .fxRate: return [.week, .month, .year]
        case .netWorth, .investingRatio, .cashflow: return [.month, .year]
        case .currencyExposure, .upcomingBills: return []
        }
    }

    /// What this widget is set to when it opens — and, since nothing
    /// persists a config, every time it opens.
    public var defaultConfig: WidgetConfig {
        switch self {
        case .netWorth:
            return WidgetConfig(metric: .netWorth)
        case .investingRatio:
            return WidgetConfig(metric: .investingRatio, visualization: .bar)
        case .cashflow:
            return WidgetConfig(metric: .cashflowNet, visualization: .bar)
        case .fxRate:
            return WidgetConfig(metric: .fxRate)
        case .currencyExposure, .upcomingBills:
            // Neither charts a time series. They carry a config so that
            // every widget is constructed the same way, not because either
            // has anything to vary yet.
            return WidgetConfig(metric: .netWorth)
        }
    }

    /// Extra metrics this widget plots on the same axis as its own.
    ///
    /// Part of the widget's *definition* rather than something the view wires
    /// up on appear, and that distinction was a real bug: set from
    /// `.onAppear`, Cashflow's first load could run before the companions
    /// existed, and the widget opened showing its net line with both bar
    /// series silently missing.
    ///
    /// Cashflow's three come out of one query per bucket (see
    /// `DashboardMetricSeries.flows`), so asking for all three costs what
    /// asking for one does.
    public var companionMetrics: [MetricKind] {
        switch self {
        case .cashflow:
            return [.moneyIn, .moneyOut]
        case .netWorth, .investingRatio, .fxRate, .currencyExposure, .upcomingBills:
            return []
        }
    }

    /// Whether this widget charts a series at all — which is what decides
    /// if it gets a timeframe filter in its expanded header.
    public var hasTimeframeFilter: Bool { !allowedGranularities.isEmpty }
}

// MARK: - Tile

/// One widget on one dashboard, at one place. `id` is per-instance, not
/// per-kind: nothing here stops a user from putting two Cashflow widgets on
/// different rows with different period filters, and an id keyed on `kind`
/// would quietly make that impossible.
public struct DashboardTile: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public let kind: DashboardWidgetKind
    public var row: Int
    public var column: Int

    public init(id: UUID = UUID(), kind: DashboardWidgetKind, row: Int, column: Int) {
        self.id = id
        self.kind = kind
        self.row = row
        self.column = column
    }

    public var size: DashboardWidgetSize { kind.baseSize }

    /// The cells this tile covers at rest — both axes, since a row is half a
    /// widget and every base size spans more than one of them.
    var columnRange: Range<Int> { column ..< (column + size.columns) }
    var rowRange: Range<Int> { row ..< (row + size.rows) }
}
