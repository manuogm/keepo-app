import Foundation
import Supabase

/// Phase 18: CSV import. `importRows` is the one write for an entire parsed
/// statement (`import_csv_rows` inserts the batch and every candidate, with
/// matching computed server-side, in one round trip) — never one RPC call
/// per row. `accept`/`reject` are the two review actions; nothing here ever
/// writes a `transactions` row directly, matching capture_transaction's own
/// "only a vetted RPC writes this table" precedent.
public enum ImportRepository {
    public static func importRows(
        client: SupabaseClient, accountId: UUID, filename: String, rows: [CSVImportRow], currency: String
    ) async throws -> [PublicSchema.CsvImportCandidatesSelect] {
        let payload = rows.map { row in
            ImportRowPayload(
                occurredAt: PostgresDate.timestampString(row.occurredAt),
                amountE4: row.amountE4,
                currency: currency,
                merchantRaw: row.merchantRaw,
                merchantNormalized: row.merchantRaw.map(MerchantNormalizer.normalize)
            )
        }
        let params = ImportCsvRowsParams(accountId: accountId, filename: filename, rows: payload)
        return try await client.rpc("import_csv_rows", params: params).execute().value
    }

    public static func fetchCandidates(
        client: SupabaseClient, batchId: UUID
    ) async throws -> [PublicSchema.CsvImportCandidatesSelect] {
        try await client.from("csv_import_candidates")
            .select()
            .eq("batch_id", value: batchId)
            .order("occurred_at", ascending: false)
            .execute()
            .value
    }

    @discardableResult
    public static func accept(client: SupabaseClient, id: UUID) async throws -> WriteResult {
        let rows: [ConflictRow] = try await client.rpc("accept_import_candidate", params: CandidateIdParam(id: id))
            .execute()
            .value
        return rows.first.map(WriteResult.init) ?? .conflict
    }

    public static func reject(client: SupabaseClient, id: UUID) async throws {
        try await client.rpc("reject_import_candidate", params: CandidateIdParam(id: id)).execute()
    }
}

private struct ImportRowPayload: Encodable {
    let occurredAt: String
    let amountE4: Int64
    let currency: String
    let merchantRaw: String?
    let merchantNormalized: String?
    enum CodingKeys: String, CodingKey {
        case occurredAt = "occurred_at"
        case amountE4 = "amount_e4"
        case currency
        case merchantRaw = "merchant_raw"
        case merchantNormalized = "merchant_normalized"
    }
}

private struct ImportCsvRowsParams: Encodable {
    let accountId: UUID
    let filename: String
    let rows: [ImportRowPayload]
    enum CodingKeys: String, CodingKey {
        case accountId = "p_account_id"
        case filename = "p_filename"
        case rows = "p_rows"
    }
}

private struct CandidateIdParam: Encodable {
    let id: UUID
    enum CodingKeys: String, CodingKey {
        case id = "p_id"
    }
}
