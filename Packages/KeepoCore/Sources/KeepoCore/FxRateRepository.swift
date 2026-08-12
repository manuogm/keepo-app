import Foundation
import Supabase

/// `fx_rates` is readable by every authenticated user (`fx_rates_select`
/// `using (true)`) — rates aren't per-owner data, so this needs no RPC and
/// no migration, just a plain ordered-and-limited select.
public enum FxRateRepository {
    public static func latestFetchedAt(client: SupabaseClient) async throws -> Date? {
        let rows: [FetchedAtRow] = try await client.from("fx_rates")
            .select("fetched_at")
            .order("fetched_at", ascending: false)
            .limit(1)
            .execute()
            .value
        guard let raw = rows.first?.fetchedAt else { return nil }
        return PostgresDate.date(fromTimestamp: raw)
    }
}

private struct FetchedAtRow: Decodable {
    let fetchedAt: String
    enum CodingKeys: String, CodingKey {
        case fetchedAt = "fetched_at"
    }
}
