import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// The arming half of the rating ask — the part that runs at a capture's
/// write, including when that write comes from a notification quick action
/// with the app backgrounded.
@Suite("Review prompter arming")
struct ReviewPrompterTests {
    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        try migrator.migrate(dbQueue)
        return dbQueue
    }

    private func seedCategory(_ database: Database, ownerId: UUID, id: UUID) throws {
        try database.execute(
            sql: """
            INSERT INTO categories (id, owner_id, kind, name, is_default, icon, color, version,
                created_at, updated_at, sync_seq)
            VALUES (?, ?, 'expense', 'Other', 1, 'tag.fill', '#8E8E93', 1,
                '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
            """,
            arguments: [id.uuidString, ownerId.uuidString]
        )
    }

    /// The four ids a seeded capture needs, so the helper stays inside the
    /// project's parameter-count lint without the call sites losing their
    /// labels.
    private struct Seed {
        let ownerId: UUID
        let categoryId: UUID
        let id: UUID
    }

    private func seedCapture(_ database: Database, _ seed: Seed, card: String, status: String) throws {
        let ownerId = seed.ownerId
        let categoryId = seed.categoryId
        let id = seed.id
        try database.execute(
            sql: """
            INSERT INTO transactions (id, owner_id, created_by, account_id, category_id, amount_e4,
                currency, occurred_at, merchant_raw, merchant_normalized, card_identifier, source,
                status, external_id, version, created_at, updated_at, sync_seq)
            VALUES (?, ?, ?, NULL, ?, -5000, NULL, '2026-09-16T10:00:00.000000+00:00',
                'Shop', 'SHOP', ?, 'capture', ?, ?, 1,
                '2026-09-16T10:00:00.000000+00:00', '2026-09-16T10:00:00.000000+00:00', 0)
            """,
            arguments: [
                id.uuidString, ownerId.uuidString, ownerId.uuidString, categoryId.uuidString,
                card, status, id.uuidString
            ]
        )
    }

    /// Cleared before and after, so these never inherit or leave state on
    /// the simulator's real settings.
    private func resetDefaults() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: AppSettingsKeys.capturesReviewed)
        defaults.removeObject(forKey: AppSettingsKeys.reviewPromptArmed)
        defaults.removeObject(forKey: AppSettingsKeys.lastReviewRequestAt)
    }

    /// The full primary trigger: two captures reviewed, the second one
    /// leaving the inbox empty.
    @Test("resolving the last capture arms the prompt once the bar is met")
    func armsOnTheSecondCapture() async throws {
        resetDefaults()
        defer { resetDefaults() }

        let dbQueue = try makeDatabase()
        let ownerId = UUID()
        let categoryId = UUID()
        let first = UUID()
        let second = UUID()
        try await dbQueue.write { database in
            try seedCategory(database, ownerId: ownerId, id: categoryId)
            try seedCapture(
                database, Seed(ownerId: ownerId, categoryId: categoryId, id: first),
                card: "Visa", status: "confirmed"
            )
            try seedCapture(
                database, Seed(ownerId: ownerId, categoryId: categoryId, id: second),
                card: "Visa", status: "confirmed"
            )
        }

        await ReviewPrompter.recordCaptureResolved(id: first, dbQueue: dbQueue)
        #expect(ReviewPrompter.state.capturesReviewed == 1)
        // One capture reviewed is not enough, however clear the inbox.
        #expect(ReviewPrompter.state.isArmed == false)

        await ReviewPrompter.recordCaptureResolved(id: second, dbQueue: dbQueue)
        #expect(ReviewPrompter.state.capturesReviewed == 2)
        #expect(ReviewPrompter.state.isArmed)
    }

    @Test("a capture still pending in the inbox holds the prompt back")
    func inboxMustBeClear() async throws {
        resetDefaults()
        defer { resetDefaults() }

        let dbQueue = try makeDatabase()
        let ownerId = UUID()
        let categoryId = UUID()
        let resolved = UUID()
        try await dbQueue.write { database in
            try seedCategory(database, ownerId: ownerId, id: categoryId)
            try seedCapture(
                database, Seed(ownerId: ownerId, categoryId: categoryId, id: resolved),
                card: "Visa", status: "confirmed"
            )
            try seedCapture(
                database, Seed(ownerId: ownerId, categoryId: categoryId, id: UUID()),
                card: "Visa", status: "pending"
            )
        }
        UserDefaults.standard.set(5, forKey: AppSettingsKeys.capturesReviewed)

        await ReviewPrompter.recordCaptureResolved(id: resolved, dbQueue: dbQueue)
        #expect(ReviewPrompter.state.capturesReviewed == 6)
        #expect(ReviewPrompter.state.isArmed == false)
    }

    /// **Onboarding must not contribute to the bar it sits behind.** The
    /// test capture is a real local row and the transactions list can
    /// confirm one, so the skip has to be explicit.
    @Test("onboarding's test capture counts for nothing")
    func testCaptureIsSkipped() async throws {
        resetDefaults()
        defer { resetDefaults() }

        let dbQueue = try makeDatabase()
        let ownerId = UUID()
        let categoryId = UUID()
        let testId = UUID()
        try await dbQueue.write { database in
            try seedCategory(database, ownerId: ownerId, id: categoryId)
            try seedCapture(
                database, Seed(ownerId: ownerId, categoryId: categoryId, id: testId),
                card: CaptureIdentity.testCardIdentifier, status: "confirmed"
            )
        }
        UserDefaults.standard.set(1, forKey: AppSettingsKeys.capturesReviewed)

        await ReviewPrompter.recordCaptureResolved(id: testId, dbQueue: dbQueue)
        #expect(ReviewPrompter.state.capturesReviewed == 1)
        #expect(ReviewPrompter.state.isArmed == false)
    }

    /// A test capture left sitting in the ledger must not hold a genuine
    /// arming back either — it is excluded from the remaining count for
    /// the same reason it is excluded from Needs Review.
    @Test("a leftover test capture does not count as an unresolved one")
    func testCaptureDoesNotBlockArming() async throws {
        resetDefaults()
        defer { resetDefaults() }

        let dbQueue = try makeDatabase()
        let ownerId = UUID()
        let categoryId = UUID()
        let real = UUID()
        try await dbQueue.write { database in
            try seedCategory(database, ownerId: ownerId, id: categoryId)
            try seedCapture(
                database, Seed(ownerId: ownerId, categoryId: categoryId, id: real),
                card: "Visa", status: "confirmed"
            )
            try seedCapture(
                database, Seed(ownerId: ownerId, categoryId: categoryId, id: UUID()),
                card: CaptureIdentity.testCardIdentifier, status: "pending"
            )
        }
        UserDefaults.standard.set(4, forKey: AppSettingsKeys.capturesReviewed)

        await ReviewPrompter.recordCaptureResolved(id: real, dbQueue: dbQueue)
        #expect(ReviewPrompter.state.isArmed)
    }

    /// One arming, one ask. `markAsked` is what makes it one-shot, and it
    /// runs whether or not iOS displayed anything — because there is no way
    /// to find out, and a call that showed nothing still has to start the
    /// re-ask clock.
    @Test("asking disarms and starts the re-ask clock")
    func askingIsOneShot() {
        resetDefaults()
        defer { resetDefaults() }

        UserDefaults.standard.set(true, forKey: AppSettingsKeys.reviewPromptArmed)
        #expect(ReviewPrompter.isDue(signedUpAt: nil))

        ReviewPrompter.markAsked()
        #expect(ReviewPrompter.state.isArmed == false)
        #expect(ReviewPrompter.state.lastRequestedAt != nil)
        #expect(ReviewPrompter.isDue(signedUpAt: nil) == false)
    }
}
