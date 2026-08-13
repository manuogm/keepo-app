import Foundation
import Supabase

public enum InsightsRepository {
    public static func spendingByCategory(
        client: SupabaseClient, scope: PublicSchema.AccountScope, from: Date, through: Date
    ) async throws -> [CategorySpending] {
        let params = ScopeRangeParams(
            scope: scope, from: PostgresDate.dateOnlyString(from), through: PostgresDate.dateOnlyString(through)
        )
        return try await client.rpc("spending_by_category", params: params).execute().value
    }

    /// `granularity` is chosen client-side from the span via
    /// `DateBucketing.granularity(from:through:)` and passed straight
    /// through — never recomputed here, matching the "derived from the
    /// span, never a user control" rule Home's own trajectory already
    /// follows (app-architecture.md §5).
    public static func incomeExpenseSeries(
        client: SupabaseClient, scope: PublicSchema.AccountScope, from: Date, through: Date,
        granularity: DateBucketing.Granularity
    ) async throws -> [IncomeExpensePoint] {
        let params = SeriesParams(
            scope: scope, from: PostgresDate.dateOnlyString(from), through: PostgresDate.dateOnlyString(through),
            granularity: granularity == .monthly ? "monthly" : "weekly"
        )
        return try await client.rpc("income_expense_series", params: params).execute().value
    }

    public static func savingsRate(
        client: SupabaseClient, scope: PublicSchema.AccountScope, from: Date, through: Date
    ) async throws -> Decimal? {
        let params = ScopeRangeParams(
            scope: scope, from: PostgresDate.dateOnlyString(from), through: PostgresDate.dateOnlyString(through)
        )
        return try await client.rpc("savings_rate", params: params).execute().value
    }

    /// `nil` before any `balance_snapshots` row exists for the account —
    /// money rule 5, never a `0` standing in for "not yet knowable."
    public static func unrealizedGain(client: SupabaseClient, accountId: UUID) async throws -> Int64? {
        try await client.rpc("unrealized_gain", params: AccountIdParam(accountId: accountId)).execute().value
    }
}

public struct CategorySpending: Decodable, Sendable {
    public let categoryId: UUID
    public let categoryName: String
    public let totalE4: Int64?
    public let currency: String
    enum CodingKeys: String, CodingKey {
        case categoryId = "category_id"
        case categoryName = "category_name"
        case totalE4 = "total_e4"
        case currency
    }
}

public struct IncomeExpensePoint: Decodable, Sendable {
    public let bucketStart: String
    public let incomeE4: Int64?
    public let expenseE4: Int64?
    enum CodingKeys: String, CodingKey {
        case bucketStart = "bucket_start"
        case incomeE4 = "income_e4"
        case expenseE4 = "expense_e4"
    }
}

private struct ScopeRangeParams: Encodable {
    let scope: PublicSchema.AccountScope
    let from: String
    let through: String
    enum CodingKeys: String, CodingKey {
        case scope = "p_scope"
        case from = "p_from"
        case through = "p_to"
    }
}

private struct SeriesParams: Encodable {
    let scope: PublicSchema.AccountScope
    let from: String
    let through: String
    let granularity: String
    enum CodingKeys: String, CodingKey {
        case scope = "p_scope"
        case from = "p_from"
        case through = "p_to"
        case granularity = "p_granularity"
    }
}

private struct AccountIdParam: Encodable {
    let accountId: UUID
    enum CodingKeys: String, CodingKey {
        case accountId = "p_account_id"
    }
}
