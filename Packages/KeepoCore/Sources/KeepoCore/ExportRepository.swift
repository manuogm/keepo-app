import Foundation
import Supabase

/// Phase 18: export. No new read RPC — the client already has everything
/// it needs via `TransactionRepository.fetchAll`/`transactions_with_details`;
/// this only builds the CSV text from rows already fetched and writes the
/// audit trail immediately afterward. The step-up re-auth the spec requires
/// "immediately before generation" is the caller's job (`SessionStore.
/// stepUp(reason:)`, Phase 17) — this type has no opinion on when it runs,
/// only that `logExport` is called once the CSV actually exists.
public enum ExportRepository {
    /// Every transaction on one or more of the caller's own/shared
    /// accounts — scoped server-side via `.in` and, when given, an
    /// `occurred_at` range — never fetched in full and filtered
    /// client-side. `from`/`through` both `nil` means all time.
    public static func fetchTransactions(
        client: SupabaseClient, accountIds: [UUID], from: Date? = nil, through: Date? = nil
    ) async throws -> [PublicSchema.TransactionsWithDetailsSelect] {
        var query = client.from("transactions_with_details")
            .select()
            .in("account_id", values: accountIds)
        if let from {
            query = query.gte("occurred_at", value: PostgresDate.timestampString(from))
        }
        if let through {
            query = query.lte("occurred_at", value: PostgresDate.timestampString(through))
        }
        return try await query
            .order("occurred_at", ascending: false)
            .execute()
            .value
    }

    /// One field per column, comma-joined, quoting any field that itself
    /// contains a comma or quote — the write side of the same RFC 4180
    /// subset `CSVImportParser` reads.
    public static func csv(from rows: [PublicSchema.TransactionsWithDetailsSelect]) -> String {
        var lines = ["Date,Account,Category,Merchant,Amount,Currency"]
        for row in rows {
            let amountText: String = row.amountE4.map { amountE4 in "\(Decimal(amountE4) / Decimal(10_000))" } ?? ""
            let fields: [String] = [
                row.occurredAt ?? "",
                row.accountName ?? "",
                row.categoryName ?? "",
                row.merchantRaw ?? "",
                amountText,
                row.currency ?? ""
            ]
            lines.append(fields.map(quoteIfNeeded).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    private static func quoteIfNeeded(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    @discardableResult
    public static func logExport(
        client: SupabaseClient, accountIds: [UUID], rowCount: Int
    ) async throws -> PublicSchema.ExportAuditLogSelect {
        let params = LogExportParams(accountIds: accountIds, rowCount: rowCount)
        return try await client.rpc("log_export", params: params).execute().value
    }
}

private struct LogExportParams: Encodable {
    let accountIds: [UUID]
    let rowCount: Int
    enum CodingKeys: String, CodingKey {
        case accountIds = "p_account_ids"
        case rowCount = "p_row_count"
    }
}
