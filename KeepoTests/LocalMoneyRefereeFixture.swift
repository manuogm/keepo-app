import Foundation
import GRDB

/// The exact fixture inserted into local Postgres to capture
/// `LocalMoneyRefereeTests`' pinned expected values — same ids, amounts,
/// and dates, reproduced here against the local GRDB schema instead. Split
/// into its own file purely to stay under this project's `file_length`
/// lint limit for the test file itself.
enum RefereeFixture {
    static let ownerId = "77777777-7777-7777-7777-777777777777"
    static let eurChecking = "99999999-0000-0000-0000-000000000001"
    static let usdSavings = "99999999-0000-0000-0000-000000000002"
    static let jpyWallet = "99999999-0000-0000-0000-000000000003"
    static let gbpCash = "99999999-0000-0000-0000-000000000004"
    static let eurBrokerage = "99999999-0000-0000-0000-000000000005"
    static let groceries = "88888888-0000-0000-0000-000000000001"
    static let salary = "88888888-0000-0000-0000-000000000002"

    private struct Account {
        let id: String
        let kind: String
        let currency: String
        let opening: Int64
    }

    private struct Transaction {
        let id: String
        let accountId: String
        let categoryId: String?
        let categoryKind: String?
        let amount: Int64
        let currency: String
        let occurredAt: String
    }

    static func seed(_ database: Database) throws {
        try seedCurrencies(database)
        try seedProfile(database)
        try seedCategories(database)
        try seedAccounts(database)
        try seedFxRates(database)
        try seedValuationLeg(database)
        try seedTransactions(database)
        try seedBudget(database)
    }

    private static func seedCurrencies(_ database: Database) throws {
        for (code, minorUnit) in [("EUR", 2), ("USD", 2), ("JPY", 0), ("GBP", 2)] {
            try database.execute(
                sql: "INSERT INTO currencies (code, minor_unit, sync_seq) VALUES (?, ?, 1)",
                arguments: [code, minorUnit]
            )
        }
    }

    private static func seedProfile(_ database: Database) throws {
        try database.execute(
            sql: """
            INSERT INTO profiles (id, base_currency, onboarded_at, created_at, updated_at, sync_epoch, sync_seq)
            VALUES (?, 'EUR', '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00',
                    '2026-01-01T00:00:00.000000+00:00', 1, 1)
            """,
            arguments: [ownerId]
        )
    }

    private static func seedCategories(_ database: Database) throws {
        for (id, kind, name) in [(groceries, "expense", "Groceries"), (salary, "income", "Salary")] {
            try database.execute(
                sql: """
                INSERT INTO categories (
                    id, owner_id, kind, name, is_default, icon, color, version, created_at, updated_at, sync_seq
                )
                VALUES (?, ?, ?, ?, 0, 'cart', '#FF0000', 1, '2026-01-01T00:00:00.000000+00:00',
                        '2026-01-01T00:00:00.000000+00:00', 1)
                """,
                arguments: [id, ownerId, kind, name]
            )
        }
    }

    private static func seedAccounts(_ database: Database) throws {
        let accounts = [
            Account(id: eurChecking, kind: "ledger", currency: "EUR", opening: 10_000_000),
            Account(id: usdSavings, kind: "ledger", currency: "USD", opening: 5_000_000),
            Account(id: jpyWallet, kind: "ledger", currency: "JPY", opening: 100_000_000),
            Account(id: gbpCash, kind: "ledger", currency: "GBP", opening: 2_000_000),
            Account(id: eurBrokerage, kind: "valuation", currency: "EUR", opening: 0)
        ]
        for account in accounts {
            try database.execute(
                sql: """
                INSERT INTO accounts (
                    id, owner_id, created_by, kind, subtype, name, currency, opening_balance_e4, opening_balance_at,
                    include_in_total, icon, color, version, created_at, updated_at, sync_seq
                ) VALUES (?, ?, ?, ?, 'checking', ?, ?, ?, '2026-01-01', 1, 'banknote', '#8E8E93', 1,
                          '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
                """,
                arguments: [
                    account.id, ownerId, ownerId, account.kind, account.id, account.currency, account.opening
                ]
            )
        }
    }

    private static func seedFxRates(_ database: Database) throws {
        for (currency, rate) in [("USD", "0.9000"), ("JPY", "0.0060")] {
            try database.execute(
                sql: """
                INSERT INTO fx_rates (currency, rate_date, rate_to_eur, source, fetched_at, sync_seq)
                VALUES (?, '2026-07-01', ?, 'ecb', '2026-07-01T00:00:00.000000+00:00', 1)
                """,
                arguments: [currency, rate]
            )
        }
    }

    private static func seedValuationLeg(_ database: Database) throws {
        try database.execute(
            sql: """
            INSERT INTO balance_snapshots (id, account_id, currency, as_of, value_e4, created_by, created_at, sync_seq)
            VALUES ('aaaaaaaa-0000-0000-0000-000000000001', ?, 'EUR', '2026-07-01', 50000000, ?,
                    '2026-07-01T00:00:00.000000+00:00', 1)
            """,
            arguments: [eurBrokerage, ownerId]
        )
    }

    private static func seedTransactions(_ database: Database) throws {
        for transaction in transactionFixtures {
            try insertTransaction(transaction, into: database)
        }
    }

    private static let transactionFixtures: [Transaction] = [
        Transaction(
            id: "aaaaaaaa-0000-0000-0000-000000000002", accountId: eurBrokerage, categoryId: nil, categoryKind: nil,
            amount: 10_000_000, currency: "EUR", occurredAt: "2026-07-15T00:00:00.000000+00:00"
        ),
        Transaction(
            id: "cccccccc-0000-0000-0000-000000000001", accountId: eurChecking, categoryId: groceries,
            categoryKind: "expense", amount: -500_000, currency: "EUR", occurredAt: "2026-07-05T09:00:00.000000+00:00"
        ),
        Transaction(
            id: "cccccccc-0000-0000-0000-000000000002", accountId: eurChecking, categoryId: salary,
            categoryKind: "income", amount: 20_000_000, currency: "EUR", occurredAt: "2026-07-10T09:00:00.000000+00:00"
        ),
        Transaction(
            id: "cccccccc-0000-0000-0000-000000000003", accountId: usdSavings, categoryId: groceries,
            categoryKind: "expense", amount: -300_000, currency: "USD", occurredAt: "2026-07-06T09:00:00.000000+00:00"
        ),
        Transaction(
            id: "cccccccc-0000-0000-0000-000000000004", accountId: jpyWallet, categoryId: groceries,
            categoryKind: "expense", amount: -30_000_000, currency: "JPY",
            occurredAt: "2026-07-07T09:00:00.000000+00:00"
        ),
        Transaction(
            id: "cccccccc-0000-0000-0000-000000000005", accountId: gbpCash, categoryId: groceries,
            categoryKind: "expense", amount: -200_000, currency: "GBP", occurredAt: "2026-07-08T09:00:00.000000+00:00"
        ),
        Transaction(
            id: "cccccccc-0000-0000-0000-000000000006", accountId: eurChecking, categoryId: groceries,
            categoryKind: "expense", amount: -120_000, currency: "EUR", occurredAt: "2026-08-02T09:00:00.000000+00:00"
        ),
        Transaction(
            id: "cccccccc-0000-0000-0000-000000000007", accountId: eurChecking, categoryId: salary,
            categoryKind: "income", amount: 21_000_000, currency: "EUR", occurredAt: "2026-08-05T09:00:00.000000+00:00"
        )
    ]

    private static func insertTransaction(_ transaction: Transaction, into database: Database) throws {
        try database.execute(
            sql: """
            INSERT INTO transactions (
                id, owner_id, created_by, account_id, category_id, category_kind, amount_e4, currency,
                occurred_at, source, status, version, created_at, updated_at, sync_seq
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'manual', 'confirmed', 1, ?, ?, 1)
            """,
            arguments: [
                transaction.id, ownerId, ownerId, transaction.accountId, transaction.categoryId,
                transaction.categoryKind, transaction.amount, transaction.currency, transaction.occurredAt,
                transaction.occurredAt, transaction.occurredAt
            ]
        )
    }

    private static func seedBudget(_ database: Database) throws {
        try database.execute(
            sql: """
            INSERT INTO budgets (
                id, owner_id, category_id, period_month, amount_e4, currency, version, created_at, updated_at, sync_seq
            )
            VALUES ('dddddddd-0000-0000-0000-000000000001', ?, ?, '2026-07-01', 1000000, 'EUR', 1,
                    '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
            """,
            arguments: [ownerId, groceries]
        )
    }
}
