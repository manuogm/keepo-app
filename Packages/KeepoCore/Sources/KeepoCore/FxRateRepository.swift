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

    /// The most recent `rate_to_eur` per currency — enough to convert a
    /// *pending* (not-yet-synced) transaction's amount into base currency
    /// for an offline net-worth estimate. Not a substitute for `fx_convert`
    /// (which resolves the rate at a specific historical date, with
    /// carry-forward); this is deliberately "whatever's freshest," cached
    /// on-device so the conversion still works offline. `limit(200)`
    /// rather than a `DISTINCT ON` query PostgREST's fluent builder can't
    /// express — ordering by `rate_date desc` means every currency's
    /// latest row sorts before any currency's older one, so 200 rows
    /// covers every supported currency with room to spare; the loop below
    /// keeps only the first (freshest) row per currency.
    public static func fetchLatestRates(client: SupabaseClient) async throws -> [String: Decimal] {
        let rows: [RateRow] = try await client.from("fx_rates")
            .select("currency, rate_to_eur")
            .order("rate_date", ascending: false)
            .limit(200)
            .execute()
            .value
        var result: [String: Decimal] = [:]
        for row in rows where result[row.currency] == nil {
            result[row.currency] = row.rateToEur
        }
        return result
    }
}

private struct RateRow: Decodable {
    let currency: String
    let rateToEur: Decimal
    enum CodingKeys: String, CodingKey {
        case currency
        case rateToEur = "rate_to_eur"
    }
}

private struct FetchedAtRow: Decodable {
    let fetchedAt: String
    enum CodingKeys: String, CodingKey {
        case fetchedAt = "fetched_at"
    }
}
