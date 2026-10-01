import Foundation
import Supabase

/// The export's one server call: the audit row.
///
/// The export itself is built on the device, from the same local mirror the
/// Transactions list reads (`ExportBuilder` in the app), so the file contains
/// exactly what the user filtered — including a write still waiting in the
/// outbox. What cannot happen locally is the record that it happened: the
/// spec calls an export "the highest-value target in the app", and the audit
/// row is how one is always detectable afterwards. The caller's step-up
/// re-auth (`SessionStore.stepUp(reason:)`) runs before the file is built;
/// this runs once it exists.
public enum ExportRepository {
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
