import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// The ledger's filter axes as SQL — `LocalTransactionRow+Filtering`.
///
/// The multi-value axes are the point: every one of them is an `IN (…)` built
/// from a `Set`, and the three things worth pinning are that several values
/// mean OR *within* an axis, that axes still AND *across* each other, and that
/// an empty set means no rows rather than every row.
@Suite("Transaction filter query")
struct TransactionFilterQueryTests {
    private let owner = UUID().uuidString
    private let partner = UUID().uuidString

    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        try migrator.migrate(dbQueue)
        return dbQueue
    }

    /// One account, three categories (two expense, one income), and four
    /// transactions: groceries and transport paid by the owner, a salary, and
    /// a grocery shop the partner entered on the same (shared) account.
    private struct Fixture {
        let accountId: String
        let groceries: UUID
        let transport: UUID
        let salary: UUID
    }

    private func seed(_ database: Database) throws -> Fixture {
        let accountId = UUID().uuidString
        try database.execute(sql: "INSERT INTO currencies (code, minor_unit, sync_seq) VALUES ('EUR', 2, 1)")
        try database.execute(
            sql: """
            INSERT INTO accounts (id, owner_id, created_by, kind, name, currency,
                opening_balance_e4, opening_balance_at, include_in_total, icon, color, version,
                created_at, updated_at, sync_seq)
            VALUES (?, ?, ?, 'regular', 'Joint', 'EUR', 0, '2026-01-01', 1, 'banknote', '#8E8E93', 1,
                '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
            """,
            arguments: [accountId, owner, owner]
        )
        let groceries = try insertCategory(database, name: "Groceries", kind: "expense")
        let transport = try insertCategory(database, name: "Transport", kind: "expense")
        let salary = try insertCategory(database, name: "Salary", kind: "income")

        let shop = try insert(
            database, accountId: accountId, category: groceries, amountE4: -5000, createdBy: owner,
            title: "Corner shop", notes: "Ran out of milk"
        )
        try tag(database, named: "Holiday", on: shop)
        try insert(
            database, accountId: accountId, category: transport, amountE4: -2000, createdBy: owner,
            title: "Bus fare", source: "capture"
        )
        try insert(database, accountId: accountId, category: salary, amountE4: 300_000, createdBy: owner)
        try insert(database, accountId: accountId, category: groceries, amountE4: -1500, createdBy: partner)

        return Fixture(accountId: accountId, groceries: groceries, transport: transport, salary: salary)
    }

    private func insertCategory(_ database: Database, name: String, kind: String) throws -> UUID {
        let id = UUID()
        try database.execute(
            sql: """
            INSERT INTO categories (id, owner_id, kind, name, is_default, icon, color, version,
                created_at, updated_at, sync_seq)
            VALUES (?, ?, ?, ?, 0, 'cart', '#000', 1,
                '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
            """,
            arguments: [id.uuidString, owner, kind, name]
        )
        return id
    }

    @discardableResult
    private func insert(
        _ database: Database, accountId: String, category: UUID, amountE4: Int64, createdBy: String,
        title: String? = nil, notes: String? = nil, source: String = "manual"
    ) throws -> String {
        let id = UUID().uuidString
        try database.execute(
            sql: """
            INSERT INTO transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency,
                occurred_at, source, status, version, created_at, updated_at, sync_seq, title, notes)
            VALUES (?, ?, ?, ?, ?, ?, 'EUR', '2026-06-15T12:00:00.000000+00:00', ?, 'confirmed', 1,
                '2026-06-15T12:00:00.000000+00:00', '2026-06-15T12:00:00.000000+00:00', 1, ?, ?)
            """,
            // `owner_id` is the account's owner whoever entered the row — the
            // composite FK forces it, which is exactly why the filter is on
            // `created_by` and not on `owner_id`.
            arguments: [
                id, owner, createdBy, accountId, category.uuidString, amountE4, source, title, notes
            ]
        )
        return id
    }

    /// One tag on one transaction, the shape `transaction_tags` mirrors.
    private func tag(_ database: Database, named name: String, on transactionId: String) throws {
        let tagId = UUID().uuidString
        try database.execute(
            sql: """
            INSERT INTO tags (id, owner_id, name, version, created_at, updated_at, sync_seq)
            VALUES (?, ?, ?, 1, '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
            """,
            arguments: [tagId, owner, name]
        )
        try database.execute(
            sql: """
            INSERT INTO transaction_tags (transaction_id, tag_id, owner_id, created_at, updated_at, sync_seq)
            VALUES (?, ?, ?, '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
            """,
            arguments: [transactionId, tagId, owner]
        )
    }

    private func rows(
        _ dbQueue: DatabaseQueue, _ filter: TransactionFilter
    ) async throws -> [PublicSchema.TransactionsWithDetailsSelect] {
        try await dbQueue.read { database in
            try LocalTransactionRow.fetchFiltered(
                database, filter: filter, scope: .total, baseCurrency: "EUR", ownerId: owner
            )
        }
    }

    @Test("Two categories ticked means either of them, and nothing else")
    func severalCategoriesAreOrd() async throws {
        let dbQueue = try makeDatabase()
        let fixture = try await dbQueue.write { database in try seed(database) }

        let both = try await rows(dbQueue, TransactionFilter(categoryIds: [fixture.groceries, fixture.transport]))
        #expect(both.count == 3)
        #expect(Set(both.compactMap(\.categoryName)) == ["Groceries", "Transport"])

        let one = try await rows(dbQueue, TransactionFilter(categoryIds: [fixture.salary]))
        #expect(one.count == 1)
        #expect(one.first?.categoryName == "Salary")
    }

    /// `kind` is derived in SQL rather than stored, so the type axis filters on
    /// an expression — worth pinning that it survives being put inside an
    /// `IN (…)` with several values.
    @Test("Two types ticked means either of them")
    func severalKindsAreOrd() async throws {
        let dbQueue = try makeDatabase()
        _ = try await dbQueue.write { database in try seed(database) }

        let income = try await rows(dbQueue, TransactionFilter(kinds: ["income"]))
        #expect(income.count == 1)

        let both = try await rows(dbQueue, TransactionFilter(kinds: ["income", "expense"]))
        #expect(both.count == 4)

        let transfers = try await rows(dbQueue, TransactionFilter(kinds: ["transfer"]))
        #expect(transfers.isEmpty)
    }

    /// The household axis. Both rows sit on the same account with the same
    /// `owner_id`; only `created_by` tells them apart, which is the whole
    /// reason the filter is on that column.
    @Test("Added by filters on who entered the row, not whose account it is")
    func createdByTellsMembersApart() async throws {
        let dbQueue = try makeDatabase()
        _ = try await dbQueue.write { database in try seed(database) }

        let theirs = try await rows(
            dbQueue, TransactionFilter(createdByIds: [try #require(UUID(uuidString: partner))])
        )
        #expect(theirs.count == 1)
        #expect(theirs.first?.amountE4 == -1500)

        let mine = try await rows(dbQueue, TransactionFilter(createdByIds: [try #require(UUID(uuidString: owner))]))
        #expect(mine.count == 3)
    }

    @Test("Axes AND across each other")
    func axesAnd() async throws {
        let dbQueue = try makeDatabase()
        let fixture = try await dbQueue.write { database in try seed(database) }

        let filter = TransactionFilter(
            categoryIds: [fixture.groceries],
            kinds: ["expense"],
            createdByIds: [try #require(UUID(uuidString: partner))]
        )
        let matched = try await rows(dbQueue, filter)

        #expect(matched.count == 1)
        #expect(matched.first?.amountE4 == -1500)
    }

    /// An empty set is "none of them" — `IN ()` is not valid SQLite, so
    /// `appendIn` spells it as a false clause. The ledger's own UI never
    /// produces one (`FilterSelection` resets to `nil` instead), but the
    /// export can, and "no accounts chosen" must not fall through to
    /// everything.
    @Test("An empty axis matches nothing, never everything")
    func emptyAxisMatchesNothing() async throws {
        let dbQueue = try makeDatabase()
        _ = try await dbQueue.write { database in try seed(database) }

        #expect(try await rows(dbQueue, TransactionFilter(categoryIds: [])).isEmpty)
        #expect(try await rows(dbQueue, TransactionFilter(kinds: [])).isEmpty)
        #expect(try await rows(dbQueue, TransactionFilter(createdByIds: [])).isEmpty)
        #expect(try await rows(dbQueue, TransactionFilter(accountIds: [])).isEmpty)
    }

    /// The unfiltered baseline, so a failure above can be read as "the filter
    /// is wrong" rather than "the fixture is wrong".
    @Test("No filter returns every row")
    func unfilteredReturnsEverything() async throws {
        let dbQueue = try makeDatabase()
        _ = try await dbQueue.write { database in try seed(database) }

        #expect(try await rows(dbQueue, TransactionFilter()).count == 4)
    }

    // MARK: - Source

    /// The axis this was asked for: the transactions the phone logged on the
    /// user's behalf, told apart from the ones they typed.
    @Test("Source filters captures from hand-entered rows")
    func sourceFiltersCaptures() async throws {
        let dbQueue = try makeDatabase()
        _ = try await dbQueue.write { database in try seed(database) }

        let captured = try await rows(dbQueue, TransactionFilter(sources: [.capture]))
        #expect(captured.count == 1)
        #expect(captured.first?.title == "Bus fare")

        let byHand = try await rows(dbQueue, TransactionFilter(sources: [.manual]))
        #expect(byHand.count == 3)

        // Several sources at once behave like every other axis: OR within,
        // AND across.
        #expect(try await rows(dbQueue, TransactionFilter(sources: [.capture, .manual])).count == 4)
        #expect(try await rows(dbQueue, TransactionFilter(sources: [.recurring])).isEmpty)
    }

    /// The options the drop-down offers are derived from the ledger, so it can
    /// never present one that returns nothing — and ticking them all is the
    /// same list as ticking none.
    @Test("Only the sources the ledger holds are offered, in a fixed order")
    func availableSourcesAreDerived() async throws {
        let dbQueue = try makeDatabase()
        _ = try await dbQueue.write { database in try seed(database) }

        let available = try await dbQueue.read { database in
            try LocalTransactionRow.availableSources(database, scope: .total, ownerId: owner)
        }

        #expect(available == [.capture, .manual])
        let all = try await rows(dbQueue, TransactionFilter(sources: Set(available)))
        let unfiltered = try await rows(dbQueue, TransactionFilter())
        #expect(all.count == unfiltered.count)
    }

    // MARK: - Search

    /// Everything the user typed into the transaction is searchable, which is
    /// the whole contract: the title, the note, the category, the account and
    /// the tags. One term, one row.
    @Test("Search reaches every field the user filled in")
    func searchReachesEveryField() async throws {
        let dbQueue = try makeDatabase()
        _ = try await dbQueue.write { database in try seed(database) }

        for term in ["Corner shop", "milk", "Holiday"] {
            let matched = try await rows(dbQueue, TransactionFilter(search: term))
            #expect(matched.count == 1, "\(term) should find exactly the corner shop")
            #expect(matched.first?.title == "Corner shop")
        }
        // Category and account names reach more than one row, and did before.
        #expect(try await rows(dbQueue, TransactionFilter(search: "Groceries")).count == 2)
        #expect(try await rows(dbQueue, TransactionFilter(search: "Joint")).count == 4)
    }

    /// A row with several tags is **one** row in the results, which is what
    /// the `EXISTS` is for — a join would return it once per matching tag.
    @Test("Two matching tags on one transaction still return one row")
    func tagsDoNotMultiplyRows() async throws {
        let dbQueue = try makeDatabase()
        try await dbQueue.write { database in
            let fixture = try seed(database)
            let extra = try insert(
                database, accountId: fixture.accountId, category: fixture.transport,
                amountE4: -900, createdBy: owner, title: "Taxi"
            )
            try tag(database, named: "Trip north", on: extra)
            try tag(database, named: "Trip south", on: extra)
        }

        let matched = try await rows(dbQueue, TransactionFilter(search: "Trip"))
        #expect(matched.count == 1)
        #expect(matched.first?.title == "Taxi")
    }

    /// A numeric term searches the amount **as well as** the text, and matches
    /// the magnitude exactly — an outflow is stored negative (money rule 1)
    /// and nobody searches for "-50".
    @Test("A numeric term matches the amount, sign and all")
    func numericTermMatchesAmount() async throws {
        let dbQueue = try makeDatabase()
        _ = try await dbQueue.write { database in try seed(database) }

        let outflow = try await rows(dbQueue, TransactionFilter(search: "0.50"))
        #expect(outflow.count == 1)
        #expect(outflow.first?.amountE4 == -5000)

        let inflow = try await rows(dbQueue, TransactionFilter(search: "30"))
        #expect(inflow.count == 1)
        #expect(inflow.first?.amountE4 == 300_000)

        // Exact, not prefix: 0.15 is in the ledger, 0.1 is not.
        #expect(try await rows(dbQueue, TransactionFilter(search: "0.15")).count == 1)
        #expect(try await rows(dbQueue, TransactionFilter(search: "0.1")).isEmpty)
    }

    /// The guard that keeps a text search from dragging amounts in with it.
    @Test("A term with letters searches text only")
    func termWithLettersSearchesTextOnly() async throws {
        let dbQueue = try makeDatabase()
        _ = try await dbQueue.write { database in try seed(database) }

        // "0.20 shop" would otherwise read as an amount as well, and pull in
        // the 0.20 transport row alongside the title match.
        #expect(try await rows(dbQueue, TransactionFilter(search: "0.20 shop")).isEmpty)
    }
}
