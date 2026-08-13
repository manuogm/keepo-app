import Foundation
import Supabase

/// Plain RLS-scoped table reads/writes, same reasoning as
/// `RecurringRuleRepository` — a budget is edited far less often than a
/// transaction, with no concurrent-edit hazard worth a versioned RPC layer.
public enum BudgetRepository {
    public static func fetchAll(client: SupabaseClient) async throws -> [PublicSchema.BudgetsSelect] {
        try await client.from("budgets").select().order("period_month", ascending: false).execute().value
    }

    public static func fetchProgress(client: SupabaseClient, periodMonth: Date) async throws -> [BudgetProgress] {
        let params = PeriodMonthParam(periodMonth: PostgresDate.dateOnlyString(periodMonth))
        return try await client.rpc("budget_progress", params: params).execute().value
    }

    @discardableResult
    // swiftlint:disable:next function_parameter_count
    public static func create(
        client: SupabaseClient, ownerId: UUID, categoryId: UUID?, periodMonth: Date, amountE4: Int64, currency: String
    ) async throws -> UUID {
        let id = UUID()
        let row = PublicSchema.BudgetsInsert(
            amountE4: amountE4, categoryId: categoryId, createdAt: nil, currency: currency, deletedAt: nil, id: id,
            ownerId: ownerId, periodMonth: PostgresDate.dateOnlyString(periodMonth), syncSeq: nil, updatedAt: nil,
            version: nil
        )
        try await client.from("budgets").insert(row).execute()
        return id
    }

    public static func update(client: SupabaseClient, id: UUID, amountE4: Int64, currency: String) async throws {
        let patch = PublicSchema.BudgetsUpdate(
            amountE4: amountE4, categoryId: nil, createdAt: nil, currency: currency, deletedAt: nil, id: nil,
            ownerId: nil, periodMonth: nil, syncSeq: nil, updatedAt: nil, version: nil
        )
        try await client.from("budgets").update(patch).eq("id", value: id).execute()
    }
}

public struct BudgetProgress: Decodable, Sendable {
    public let budgetId: UUID
    public let categoryId: UUID?
    public let categoryName: String?
    public let budgetedE4: Int64?
    public let spentE4: Int64?
    public let currency: String
    enum CodingKeys: String, CodingKey {
        case budgetId = "budget_id"
        case categoryId = "category_id"
        case categoryName = "category_name"
        case budgetedE4 = "budgeted_e4"
        case spentE4 = "spent_e4"
        case currency
    }
}

private struct PeriodMonthParam: Encodable {
    let periodMonth: String
    enum CodingKeys: String, CodingKey {
        case periodMonth = "p_period_month"
    }
}
