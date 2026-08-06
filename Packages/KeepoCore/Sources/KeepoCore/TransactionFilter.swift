import Foundation
import Supabase

/// Every field optional and AND'd together — an empty filter behaves
/// exactly like `TransactionRepository.fetchAll`.
public struct TransactionFilter: Equatable, Sendable {
    public var accountId: UUID?
    public var categoryId: UUID?
    public var kind: String?
    public var from: Date?
    public var through: Date?
    public var search: String?

    public init(
        accountId: UUID? = nil,
        categoryId: UUID? = nil,
        kind: String? = nil,
        from: Date? = nil,
        through: Date? = nil,
        search: String? = nil
    ) {
        self.accountId = accountId
        self.categoryId = categoryId
        self.kind = kind
        self.from = from
        self.through = through
        self.search = search
    }

    public var isEmpty: Bool {
        accountId == nil && categoryId == nil && kind == nil && from == nil && through == nil
            && (search?.isEmpty ?? true)
    }
}

public extension TransactionRepository {
    /// Every filter is optional and additive (AND'd together); `search`
    /// matches merchant/category/account name. Ordered the same way as
    /// `fetchAll`, riding the existing `(owner_id, occurred_at desc, id
    /// desc)` keyset index — filtering never changes the sort, only which
    /// rows qualify.
    static func fetchFiltered(client: SupabaseClient, filter: TransactionFilter) async throws
        -> [PublicSchema.TransactionsWithDetailsSelect] {
        var query = client.from("transactions_with_details").select()
        if let accountId = filter.accountId { query = query.eq("account_id", value: accountId) }
        if let categoryId = filter.categoryId { query = query.eq("category_id", value: categoryId) }
        if let kind = filter.kind { query = query.eq("kind", value: kind) }
        if let from = filter.from { query = query.gte("occurred_at", value: PostgresDate.timestampString(from)) }
        if let through = filter.through {
            query = query.lte("occurred_at", value: PostgresDate.timestampString(through))
        }
        if let search = filter.search, !search.isEmpty {
            let pattern = "%\(search)%"
            query = query.or(
                "merchant_raw.ilike.\(pattern),merchant_normalized.ilike.\(pattern),"
                    + "category_name.ilike.\(pattern),account_name.ilike.\(pattern)"
            )
        }
        return try await query
            .order("occurred_at", ascending: false)
            .order("transaction_id", ascending: false)
            .execute()
            .value
    }
}
