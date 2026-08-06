import Foundation
import Supabase

/// FI settings are seeded once per user at signup (`handle_new_user()`) —
/// there is always exactly one row to read and update, never an
/// upsert-on-first-view path.
public enum FIRepository {
    public static func fetchSettings(client: SupabaseClient) async throws -> PublicSchema.FiSettingsSelect? {
        let rows: [PublicSchema.FiSettingsSelect] = try await client.from("fi_settings").select().execute().value
        return rows.first
    }

    public static func updateSettings(
        client: SupabaseClient, targetAnnualSpend: Decimal?, withdrawalRate: Decimal, realReturnRate: Decimal
    ) async throws {
        let patch = PublicSchema.FiSettingsUpdate(
            ownerId: nil, realReturnRate: realReturnRate, targetAnnualSpend: targetAnnualSpend, updatedAt: nil,
            withdrawalRate: withdrawalRate
        )
        try await client.from("fi_settings").update(patch).execute()
    }

    public static func fetchMetrics(
        client: SupabaseClient, scope: PublicSchema.AccountScope
    ) async throws -> FIMetrics? {
        let rows: [FIMetrics] = try await client.rpc("fi_metrics", params: ScopeParam(scope: scope)).execute().value
        return rows.first
    }
}

public struct FIMetrics: Decodable, Sendable {
    public let annualSpend: Decimal?
    public let fiNumber: Decimal?
    public let currentNetWorth: Decimal?
    public let percentProgress: Decimal?
    public let annualSavings: Decimal?
    public let yearsToFi: Decimal?
    public let coastFiNumber: Decimal?
    enum CodingKeys: String, CodingKey {
        case annualSpend = "annual_spend"
        case fiNumber = "fi_number"
        case currentNetWorth = "current_net_worth"
        case percentProgress = "percent_progress"
        case annualSavings = "annual_savings"
        case yearsToFi = "years_to_fi"
        case coastFiNumber = "coast_fi_number"
    }
}

private struct ScopeParam: Encodable {
    let scope: PublicSchema.AccountScope
    enum CodingKeys: String, CodingKey {
        case scope = "p_scope"
    }
}
