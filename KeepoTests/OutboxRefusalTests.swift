import Foundation
import GRDB
import KeepoCore
import Supabase
import Testing
@testable import Keepo

/// What the app-wide "Couldn't Save a Change" alert says. Found on a real
/// purchase: it quoted "is not a pending capture — use update_transaction" to
/// the user. Nothing about the app's insides belongs in it.
@Suite("Outbox refusal alert")
@MainActor
struct OutboxRefusalTests {
    private func makeOutbox(sender: StubTransactionSender) throws -> Outbox {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        let dbQueue = try DatabaseQueue()
        try migrator.migrate(dbQueue)
        return Outbox(dbQueue: dbQueue, sender: sender)
    }

    @Test("a refusal the user cannot act on is described in plain words, without the server's text")
    func refusalWithoutAReasonSaysWhatHappened() async throws {
        let sender = StubTransactionSender()
        sender.deleteTransactionResult = .failure(
            PostgrestError(code: "22023", message: "transaction 1 is a transfer leg — use delete_transfer")
        )
        let outbox = try makeOutbox(sender: sender)

        _ = await outbox.submitDeleteTransaction(DeleteTransactionPayload(id: UUID(), expectedVersion: 1)).value

        let message = try #require(outbox.refusal?.message)
        #expect(outbox.refusal?.reason == nil)
        #expect(!message.contains("delete_transfer"))
        #expect(!message.contains("server"))
        #expect(message.hasPrefix("One of your recent changes couldn't be saved"))
    }

    @Test("a refusal the database explained for the user leads with that explanation")
    func refusalWithAReasonLeadsWithIt() async throws {
        let sender = StubTransactionSender()
        let sentence = "That date is before this account was shared with you. Pick a later date."
        sender.deleteTransactionResult = .failure(PostgrestError(code: "P0001", message: sentence))
        let outbox = try makeOutbox(sender: sender)

        _ = await outbox.submitDeleteTransaction(DeleteTransactionPayload(id: UUID(), expectedVersion: 1)).value

        #expect(outbox.refusal?.reason == sentence)
        #expect(outbox.refusal?.message.hasPrefix(sentence) == true)
    }
}
