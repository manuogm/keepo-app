import Foundation
import GRDB
import KeepoCore

/// What the user has chosen on the Export screen, as one value — the three
/// steps' answers plus whatever the Transactions list handed over.
struct ExportSelection: Equatable {
    /// Explicit, always. "All accounts" is resolved to the accounts it means
    /// when chosen, so the file, the count and the audit log all name the
    /// same set rather than each re-deriving "all".
    var accountIds: Set<UUID> = []
    var period: ExportPeriod?
    /// Carried over from the Transactions list's filters, each removable on
    /// the Export screen. `nil` everywhere for an export started from Profile.
    var categoryId: UUID?
    var kind: String?
    var search: String?
    var format: ExportFormat?

    /// The ledger query this selection is, or `nil` until a period is chosen.
    func filter(now: Date, calendar: Calendar) -> TransactionFilter? {
        guard let period else { return nil }
        let interval = period.interval(now: now, calendar: calendar)
        return TransactionFilter(
            categoryId: categoryId, kind: kind, from: interval?.start, through: interval?.end,
            search: search, accountIds: accountIds
        )
    }

    var hasCarriedFilters: Bool {
        categoryId != nil || kind != nil || !(search?.isEmpty ?? true)
    }
}

/// Builds the file an export produces — read from the local mirror, written
/// to a temporary file whose name says what is in it.
///
/// **Off the main actor**: a year of transactions, a PDF with several pages,
/// or a zip is enough work to hitch a spinner, and none of it needs a view.
enum ExportBuilder {
    struct Context: Sendable {
        let dbQueue: DatabaseQueue
        let ownerId: String
        let baseCurrency: String
        /// For the PDF's header: "All accounts", "Checking and Savings".
        let accountsLabel: String
        /// "September 2026", "All time".
        let periodLabel: String
    }

    struct Output {
        let url: URL
        /// Table rows written — both legs of a transfer count — which is what
        /// the audit log records.
        let rowCount: Int
    }

    static func build(
        _ format: ExportFormat, filter: TransactionFilter, context: Context
    ) async throws -> Output {
        let read = try await context.dbQueue.read { database in
            let rows = try LocalTransactionRow.fetchFiltered(
                database, filter: filter, scope: .total, baseCurrency: context.baseCurrency, ownerId: context.ownerId
            )
            // An account-less capture is still waiting to be told which
            // account it is on; the account selection already excludes it,
            // and this makes that explicit rather than incidental.
            .filter { $0.accountId != nil && $0.currency != nil }
            let tags = try LocalExportQueries.tagNames(
                database, transactionIds: rows.compactMap { $0.transactionId?.uuidString }
            )
            let totals = format == .pdf
                ? try LocalExportQueries.totals(database, filter: filter, ownerId: context.ownerId)
                : []
            return (rows: rows, tags: tags, totals: totals)
        }

        let data: Data
        switch format {
        case .csv, .excel:
            let base = CurrencyInfo(
                code: context.baseCurrency, minorUnit: Int(read.rows.first?.baseMinorUnit ?? 2)
            )
            let header = ExportTable.header(baseCurrency: context.baseCurrency)
            let cells = read.rows.map { row in
                ExportTable.cells(exportRow(row, tags: read.tags), baseCurrency: base)
            }
            data = format == .csv
                ? CSVWriter.document(header: header, rows: cells)
                : XLSXWriter.document(sheetName: "Transactions", header: header, rows: cells)
        case .pdf:
            data = ExportPDFRenderer.render(
                ExportPDFRenderer.Statement(
                    periodLabel: context.periodLabel, accountsLabel: context.accountsLabel,
                    generatedAt: Date(), totals: read.totals,
                    entries: TransactionEntry.collapsingTransfers(read.rows)
                )
            )
        }

        let url = try write(data, name: "Keepo \(context.periodLabel)", format: format)
        return Output(url: url, rowCount: read.rows.count)
    }

    /// One ledger row as the spreadsheet formats want it.
    static func exportRow(
        _ row: PublicSchema.TransactionsWithDetailsSelect, tags: [String: [String]]
    ) -> ExportRow {
        let occurredAt = row.occurredAt.flatMap(PostgresDate.date(fromTimestamp:)) ?? Date()
        let currency = CurrencyInfo(code: row.currency ?? "", minorUnit: Int(row.minorUnit ?? 2))
        let original: ExportMoney? = {
            guard let amount = row.originalAmountE4, let code = row.originalCurrency else { return nil }
            let currency = CurrencyInfo(code: code, minorUnit: Int(row.originalMinorUnit ?? 2))
            return ExportMoney(amountE4: amount, currency: currency)
        }()
        let isTransfer = row.kind == "transfer"
        return ExportRow(
            day: ExportDay(occurredAt, calendar: .current),
            title: row.title,
            merchant: row.merchantRaw,
            category: isTransfer ? nil : row.categoryName,
            account: row.accountName ?? "—",
            kind: isTransfer ? "Transfer" : (row.kind == "income" ? "Income" : "Expense"),
            amount: ExportMoney(amountE4: row.amountE4 ?? 0, currency: currency),
            baseAmountE4: row.amountBaseE4,
            original: original,
            tags: row.transactionId.flatMap { tags[$0.uuidString] } ?? [],
            notes: row.notes,
            status: row.status == .pending ? "Pending" : "Confirmed"
        )
    }

    /// Into a directory of its own, so the file can carry a readable name —
    /// "Keepo September 2026.xlsx" is what lands in the recipient's inbox —
    /// without two exports of the same month colliding.
    private static func write(_ data: Data, name: String, format: ExportFormat) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent(safeName).appendingPathExtension(format.fileExtension)
        try data.write(to: url, options: .completeFileProtection)
        return url
    }
}
