import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// The onboarding capture test writes a **real** row through a **real**
/// cross-process invocation — that is the whole reason it proves anything.
/// Which means the fake purchase has to be perfectly contained: invisible
/// to the inbox, findable for deletion, and only ever written when Keepo
/// actually asked for it.
@Suite("Onboarding capture test")
@MainActor
struct CaptureTestSessionTests {
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

    /// `card` is what every other part of the app recognises the test row
    /// by, so a capture is seeded exactly the way the intent writes one.
    private func seedCapture(
        _ database: Database, ownerId: UUID, categoryId: UUID, id: UUID, card: String
    ) throws {
        try database.execute(
            sql: """
            INSERT INTO transactions (id, owner_id, created_by, account_id, category_id, amount_e4,
                currency, occurred_at, merchant_raw, merchant_normalized, card_identifier, source,
                status, external_id, version, created_at, updated_at, sync_seq)
            VALUES (?, ?, ?, NULL, ?, -123400, NULL, '2026-09-16T10:00:00.000000+00:00',
                ?, ?, ?, 'capture', 'pending', ?, 1,
                '2026-09-16T10:00:00.000000+00:00', '2026-09-16T10:00:00.000000+00:00', 0)
            """,
            arguments: [
                id.uuidString, ownerId.uuidString, ownerId.uuidString, categoryId.uuidString,
                // Bound rather than typed out: the merchant was spelled here
                // *and* asserted against `CaptureIdentity.testMerchant`
                // below, so renaming the constant failed a test that was only
                // ever checking the seed against itself.
                CaptureIdentity.testMerchant, MerchantNormalizer.normalize(CaptureIdentity.testMerchant),
                card, id.uuidString
            ]
        )
    }

    // MARK: - Containment

    /// **The one that matters.** A test capture listed in Needs Review
    /// would invite the user to confirm canned data into their real ledger,
    /// and would make the very first inbox clear — the rating trigger —
    /// fire on a purchase that never happened.
    @Test("the test capture never appears in Needs Review")
    func excludedFromNeedsReview() throws {
        let dbQueue = try makeDatabase()
        let ownerId = UUID()
        let categoryId = UUID()
        try dbQueue.write { database in
            try seedCategory(database, ownerId: ownerId, id: categoryId)
            try seedCapture(
                database, ownerId: ownerId, categoryId: categoryId, id: UUID(),
                card: CaptureIdentity.testCardIdentifier
            )
        }
        let rows = try dbQueue.read { try LocalMoneyQueries.needsReview($0, ownerId: ownerId.uuidString) }
        #expect(rows.isEmpty)
    }

    /// The exclusion must be the test card and nothing wider — a real
    /// pending capture disappearing from the inbox would be the worse bug
    /// by far.
    @Test("a real pending capture still appears in Needs Review")
    func realCaptureStillListed() throws {
        let dbQueue = try makeDatabase()
        let ownerId = UUID()
        let categoryId = UUID()
        try dbQueue.write { database in
            try seedCategory(database, ownerId: ownerId, id: categoryId)
            try seedCapture(
                database, ownerId: ownerId, categoryId: categoryId, id: UUID(), card: "Revolut Mastercad"
            )
        }
        let rows = try dbQueue.read { try LocalMoneyQueries.needsReview($0, ownerId: ownerId.uuidString) }
        #expect(rows.count == 1)
        #expect(rows[0].kind == "pending_capture")
    }

    // MARK: - Finding it, and getting rid of it

    @Test("the test capture can be found and deleted")
    func fetchAndDelete() throws {
        let dbQueue = try makeDatabase()
        let ownerId = UUID()
        let categoryId = UUID()
        let captureId = UUID()
        try dbQueue.write { database in
            try seedCategory(database, ownerId: ownerId, id: categoryId)
            try seedCapture(
                database, ownerId: ownerId, categoryId: categoryId, id: captureId,
                card: CaptureIdentity.testCardIdentifier
            )
        }

        let found = try dbQueue.read { try TestCaptureQueries.fetch($0) }
        #expect(found?.id == captureId)
        #expect(found?.merchant == CaptureIdentity.testMerchant)
        // Stored negative: the capture write signs it, same as a real one.
        #expect(found?.amountE4 == -CaptureIdentity.testAmountE4)
        #expect(try dbQueue.read { try TestCaptureQueries.exists($0) })

        try dbQueue.write { try TestCaptureQueries.delete($0) }
        #expect(try dbQueue.read { try TestCaptureQueries.fetch($0) } == nil)
        #expect(try dbQueue.read { try TestCaptureQueries.exists($0) } == false)
    }

    @Test("deleting the test capture leaves a real one alone")
    func deleteIsScoped() throws {
        let dbQueue = try makeDatabase()
        let ownerId = UUID()
        let categoryId = UUID()
        try dbQueue.write { database in
            try seedCategory(database, ownerId: ownerId, id: categoryId)
            try seedCapture(
                database, ownerId: ownerId, categoryId: categoryId, id: UUID(),
                card: CaptureIdentity.testCardIdentifier
            )
            try seedCapture(
                database, ownerId: ownerId, categoryId: categoryId, id: UUID(), card: "Revolut Mastercad"
            )
        }
        try dbQueue.write { try TestCaptureQueries.delete($0) }
        let remaining = try dbQueue.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM transactions") ?? 0
        }
        #expect(remaining == 1)
    }

    // MARK: - The window

    /// **The safety property of the whole feature.** An all-empty
    /// invocation outside the window is a genuinely broken automation
    /// delivering nothing; treating it as the test would make a broken
    /// setup report itself as working.
    @Test("the expecting-a-test window is shut unless Keepo just opened it")
    func windowIsShutByDefault() {
        CaptureTestSession.close()
        #expect(CaptureTestSession.isExpectingTest == false)
        CaptureTestSession.open()
        #expect(CaptureTestSession.isExpectingTest)
        CaptureTestSession.close()
        #expect(CaptureTestSession.isExpectingTest == false)
    }

    // MARK: - The callback

    @Test("an x-error callback is claimed and its message surfaced verbatim")
    func errorCallbackIsVerbatim() throws {
        let coordinator = CaptureTestCoordinator.shared
        coordinator.clear()
        let url = try #require(URL(
            string: "com.manuogm.keepo://capture-test-failed?errorMessage=The%20shortcut%20was%20not%20found"
        ))
        #expect(coordinator.handle(url))
        #expect(coordinator.shortcutError == "The shortcut was not found")
        coordinator.clear()
    }

    /// `x-success` says the shortcut *finished*, which is not the same as
    /// the capture arriving — a shortcut can run and write nothing. So it
    /// clears the error and records nothing else; the pass condition is the
    /// row appearing.
    @Test("an x-success callback is claimed but records no success")
    func successCallbackRecordsNothing() throws {
        let coordinator = CaptureTestCoordinator.shared
        let url = try #require(URL(string: "com.manuogm.keepo://capture-test-ok"))
        #expect(coordinator.handle(url))
        #expect(coordinator.shortcutError == nil)
    }

    /// The magic link arrives on the same scheme, and handing it to the
    /// capture handler would swallow every sign-in.
    @Test("a magic link is not claimed by the capture handler")
    func magicLinkPassesThrough() throws {
        let url = try #require(URL(string: "com.manuogm.keepo://auth-callback#access_token=abc"))
        #expect(CaptureTestCoordinator.shared.handle(url) == false)
    }

    /// Shortcuts binds a saved shortcut to the name in the URL, so this is
    /// the string on every user's phone — it must come from the one place
    /// that also tells them what to call it.
    @Test("the test runs the shortcut the walkthrough tells the user to install")
    func urlNamesTheSameShortcut() throws {
        let url = try #require(CaptureTestSession.runShortcutURL)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "name" }?.value == ShortcutsWalkthrough.shortcutName)
        #expect(items.first { $0.name == "x-success" }?.value == "com.manuogm.keepo://capture-test-ok")
        #expect(items.first { $0.name == "x-error" }?.value == "com.manuogm.keepo://capture-test-failed")
    }
}
