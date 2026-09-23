import Foundation

/// The file types Keepo exports.
///
/// **Three, chosen for what people do next with the file**: CSV to hand to
/// anything (a spreadsheet, another finance app's importer); Excel for a
/// spreadsheet that opens with real numbers and dates whatever the reader's
/// locale — a CSV amount like `12.50` opened in a Spanish-locale Excel reads
/// as text or as 1250, the same class of bug capture hygiene fixed on the way
/// in; and PDF for a statement a person reads, prints or forwards. OFX/QIF
/// (bank-statement formats for Quicken and GnuCash) and JSON were considered
/// and left out: the first two describe one account at a time and serve a
/// shrinking niche, and a full-data JSON dump is a data-portability feature
/// with its own scope, not a format of this one.
public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv
    case excel
    case pdf

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .csv: return "CSV"
        case .excel: return "Excel"
        case .pdf: return "PDF"
        }
    }

    /// One line on what the format is *for*, which is the question the user
    /// is actually answering when they pick one.
    public var purpose: String {
        switch self {
        case .csv: return "For any spreadsheet or another finance app"
        case .excel: return "A spreadsheet with real numbers and dates"
        case .pdf: return "A statement to read, print or share"
        }
    }

    public var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .excel: return "xlsx"
        case .pdf: return "pdf"
        }
    }
}

/// A calendar day with no time and no zone — the date a transaction happened
/// on, as the user's own calendar sees it. Carried as components rather than
/// an instant, because an instant crossing into a spreadsheet's UTC-less date
/// cell is exactly the off-by-a-day bug this codebase keeps meeting at
/// calendar boundaries.
public struct ExportDay: Hashable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// `2026-09-23` — ISO 8601, which every importer reads the same way.
    public var iso: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }
}

/// A stored e4 figure and the currency it is in — the pair every money
/// field in an export carries until a writer turns it into text.
public struct ExportMoney: Equatable, Sendable {
    public let amountE4: Int64
    public let currency: CurrencyInfo

    public init(amountE4: Int64, currency: CurrencyInfo) {
        self.amountE4 = amountE4
        self.currency = currency
    }
}

/// One exported transaction — one row of the ledger's table, not one entry of
/// its screen: a transfer is two of these, one per account, so a sum over any
/// account's rows in the file still equals what that account moved.
///
/// Every money field travels as its stored e4 figure plus its currency, and
/// becomes text only in the writer, through `MoneyFormatter.plain` — so
/// rounding happens once, by the same rule the screen uses.
public struct ExportRow: Equatable, Sendable {
    public let day: ExportDay
    public let title: String?
    public let merchant: String?
    public let category: String?
    public let account: String
    /// "Expense", "Income" or "Transfer".
    public let kind: String
    public let amount: ExportMoney
    /// The same amount in the viewer's base currency, or `nil` when no rate
    /// resolves — which the file shows as an empty cell (money rule 5: a
    /// missing rate is not a zero).
    public let baseAmountE4: Int64?
    /// What was actually paid, when a purchase was made in another currency.
    public let original: ExportMoney?
    public let tags: [String]
    public let notes: String?
    /// "Confirmed" or "Pending" — a capture not yet reviewed is still real
    /// spending, and says so.
    public let status: String

    public init(
        day: ExportDay, title: String?, merchant: String?, category: String?, account: String, kind: String,
        amount: ExportMoney, baseAmountE4: Int64?, original: ExportMoney?, tags: [String], notes: String?,
        status: String
    ) {
        self.day = day
        self.title = title
        self.merchant = merchant
        self.category = category
        self.account = account
        self.kind = kind
        self.amount = amount
        self.baseAmountE4 = baseAmountE4
        self.original = original
        self.tags = tags
        self.notes = notes
        self.status = status
    }
}

/// The spreadsheet shape both CSV and Excel write — one list of columns, so
/// the two formats can never disagree about what an export contains.
public enum ExportTable {
    /// A typed cell. The writers decide how each type is spelled: CSV as text,
    /// Excel as a real number or date the reader's own locale then displays.
    public enum Cell: Equatable, Sendable {
        case text(String)
        /// A plain machine figure (`-1234.50`) and how many decimals it shows.
        case money(String, minorUnit: Int)
        case date(ExportDay)
        case empty
    }

    /// The header row. The base-currency column names the currency, because
    /// "Amount (base)" means nothing to anyone who is not us.
    public static func header(baseCurrency: String) -> [String] {
        [
            "Date", "Title", "Merchant", "Category", "Account", "Type", "Amount", "Currency",
            "Amount (\(baseCurrency))", "Original amount", "Original currency", "Tags", "Notes", "Status"
        ]
    }

    public static func cells(_ row: ExportRow, baseCurrency: CurrencyInfo) -> [Cell] {
        [
            .date(row.day),
            text(row.title),
            text(row.merchant),
            text(row.category),
            .text(row.account),
            .text(row.kind),
            money(row.amount.amountE4, row.amount.currency),
            .text(row.amount.currency.code),
            row.baseAmountE4.map { money($0, baseCurrency) } ?? .empty,
            row.original.map { money($0.amountE4, $0.currency) } ?? .empty,
            row.original.map { .text($0.currency.code) } ?? .empty,
            row.tags.isEmpty ? .empty : .text(row.tags.joined(separator: ", ")),
            text(row.notes),
            .text(row.status)
        ]
    }

    private static func text(_ value: String?) -> Cell {
        guard let value, !value.isEmpty else { return .empty }
        return .text(value)
    }

    private static func money(_ amountE4: Int64, _ currency: CurrencyInfo) -> Cell {
        .money(MoneyFormatter.plain(amountE4, currency: currency), minorUnit: currency.minorUnit)
    }
}
