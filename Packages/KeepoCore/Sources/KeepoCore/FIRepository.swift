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
        client: SupabaseClient, targetAnnualSpendE4: Int64?, withdrawalRate: Decimal, realReturnRate: Decimal
    ) async throws {
        let patch = PublicSchema.FiSettingsUpdate(
            ownerId: nil, realReturnRate: realReturnRate, targetAnnualSpendE4: targetAnnualSpendE4, updatedAt: nil,
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
    public let annualSpendE4: Int64?
    public let fiNumberE4: Int64?
    public let currentNetWorthE4: Int64?
    public let percentProgress: Decimal?
    public let annualSavingsE4: Int64?
    public let yearsToFi: Decimal?
    public let coastFiNumberE4: Int64?
    enum CodingKeys: String, CodingKey {
        case annualSpendE4 = "annual_spend_e4"
        case fiNumberE4 = "fi_number_e4"
        case currentNetWorthE4 = "current_net_worth_e4"
        case percentProgress = "percent_progress"
        case annualSavingsE4 = "annual_savings_e4"
        case yearsToFi = "years_to_fi"
        case coastFiNumberE4 = "coast_fi_number_e4"
    }
}

private struct ScopeParam: Encodable {
    let scope: PublicSchema.AccountScope
    enum CodingKeys: String, CodingKey {
        case scope = "p_scope"
    }
}
