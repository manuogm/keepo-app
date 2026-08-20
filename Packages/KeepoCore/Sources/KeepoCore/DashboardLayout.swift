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

    /// Every *base* size is exactly one row tall — the two shapes a tile can
    /// rest at. Expanded sizes are always full width (see
    /// `DashboardWidgetKind.expandedSizes`), which is what keeps the
    /// resolver below from ever having to pack a multi-row tile except the
    /// single expanded one.
    public static let small = DashboardWidgetSize(rows: 1, columns: 1)
    public static let wide = DashboardWidgetSize(rows: 1, columns: 2)
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

    public var title: String {
        switch self {
        case .netWorth: return "Net Worth"
        case .investingRatio: return "Investing Ratio"
        case .currencyExposure: return "Currency Exposure"
        case .upcomingBills: return "Upcoming Bills"
        case .cashflow: return "Cashflow"
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
        case .cashflow: return "arrow.left.arrow.right"
        }
    }

    /// One line for the catalogue — what this widget answers, not what it
    /// looks like; the preview beside it already shows that.
    public var summary: String {
        switch self {
        case .netWorth: return "Everything you own, minus what you owe, over time."
        case .investingRatio: return "How much of your net worth is invested."
        case .currencyExposure: return "Which currencies your money sits in."
        case .upcomingBills: return "What's due over the next two weeks."
        case .cashflow: return "What came in against what went out."
        }
    }

    /// "1×2" — rows by columns, the same way the design describes sizes.
    public var sizeLabel: String {
        "\(baseSize.rows)×\(baseSize.columns)"
    }

    /// The size the tile rests at, and the size it returns to in edit mode.
    public var baseSize: DashboardWidgetSize {
        switch self {
        case .investingRatio, .currencyExposure: return .small
        case .netWorth, .upcomingBills, .cashflow: return .wide
        }
    }

    /// The successive sizes a tap cycles through, in order, after the base
    /// size. **Every expanded size is full width** — a 1×1 growing to 2×1
    /// would leave its neighbour stranded beside a tall tile, which reads as
    /// a rendering bug rather than a deliberate expansion.
    ///
    /// Cashflow is the only kind with two of them: 2×2 for the in/out donut,
    /// then 3×2 when one of the two series is tapped and the category
    /// breakdown appears under it.
    public var expandedSizes: [DashboardWidgetSize] {
        switch self {
        case .cashflow:
            return [DashboardWidgetSize(rows: 2, columns: 2), DashboardWidgetSize(rows: 3, columns: 2)]
        case .netWorth, .investingRatio, .currencyExposure, .upcomingBills:
            return [DashboardWidgetSize(rows: 2, columns: 2)]
        }
    }
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

    /// The columns this tile covers at rest. Every base size is one row
    /// tall, so a row index plus this range is the whole footprint.
    var columnRange: Range<Int> { column ..< (column + size.columns) }
}
