import Foundation
import KeepoCore
import Testing
@testable import Keepo

/// `TransactionEntry.collapsingTransfers` is what stops the ledger showing a
/// transfer twice. The rules worth pinning are the two edges: a pair only
/// collapses when BOTH legs are on screen, and everything else passes
/// through untouched in its original order.
@Suite("Transfer collapsing")
struct TransactionEntryTests {
    /// The view type has no reachable initializer from the App target
    /// (Phase L6), so it is built the same way `LocalTransactionRow` builds
    /// it — through its `Codable` conformance.
    private func transaction(
        id: UUID, amountE4: Int64, account: String, transferGroupId: UUID? = nil
    ) throws -> PublicSchema.TransactionsWithDetailsSelect {
        var payload: [String: Any] = [
            "transaction_id": id.uuidString,
            "amount_e4": amountE4,
            "account_name": account,
            "currency": "EUR",
            "minor_unit": 2,
            "occurred_at": "2026-06-15T12:00:00.000000+00:00",
            "kind": transferGroupId == nil ? "expense" : "transfer"
        ]
        if let transferGroupId { payload["transfer_group_id"] = transferGroupId.uuidString }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(PublicSchema.TransactionsWithDetailsSelect.self, from: data)
    }

    @Test("both legs of a transfer become one entry, keeping the first leg's place")
    func pairsCollapse() throws {
        let groupId = UUID()
        let outgoingId = UUID()
        let incomingId = UUID()
        let rows = [
            try transaction(id: UUID(), amountE4: -1000, account: "Checking"),
            try transaction(id: outgoingId, amountE4: -20000, account: "Checking", transferGroupId: groupId),
            try transaction(id: incomingId, amountE4: 20000, account: "Savings", transferGroupId: groupId)
        ]

        let entries = TransactionEntry.collapsingTransfers(rows)

        #expect(entries.count == 2)
        #expect(entries[0].counterpart == nil)
        #expect(entries[1].transaction.transactionId == outgoingId)
        #expect(entries[1].counterpart?.transactionId == incomingId)
    }

    @Test("the receiving leg first still pairs, and stays where it was")
    func pairsRegardlessOfLegOrder() throws {
        let groupId = UUID()
        let incomingId = UUID()
        let outgoingId = UUID()
        let rows = [
            try transaction(id: incomingId, amountE4: 20000, account: "Savings", transferGroupId: groupId),
            try transaction(id: outgoingId, amountE4: -20000, account: "Checking", transferGroupId: groupId)
        ]

        let entries = TransactionEntry.collapsingTransfers(rows)

        #expect(entries.count == 1)
        #expect(entries[0].transaction.transactionId == incomingId)
        #expect(entries[0].counterpart?.transactionId == outgoingId)
    }

    @Test("a lone leg — the account filter hid its sibling — still renders on its own")
    func singleLegSurvives() throws {
        let groupId = UUID()
        let outgoingId = UUID()
        let rows = [try transaction(id: outgoingId, amountE4: -20000, account: "Checking", transferGroupId: groupId)]

        let entries = TransactionEntry.collapsingTransfers(rows)

        #expect(entries.count == 1)
        #expect(entries[0].transaction.transactionId == outgoingId)
        #expect(entries[0].counterpart == nil)
    }

    @Test("two separate transfers do not borrow each other's legs")
    func groupsStaySeparate() throws {
        let first = UUID()
        let second = UUID()
        let rows = [
            try transaction(id: UUID(), amountE4: -20000, account: "Checking", transferGroupId: first),
            try transaction(id: UUID(), amountE4: -5000, account: "Cash", transferGroupId: second),
            try transaction(id: UUID(), amountE4: 20000, account: "Savings", transferGroupId: first),
            try transaction(id: UUID(), amountE4: 5000, account: "Checking", transferGroupId: second)
        ]

        let entries = TransactionEntry.collapsingTransfers(rows)

        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.counterpart != nil })
        #expect(entries[0].transaction.transferGroupId == first)
        #expect(entries[1].transaction.transferGroupId == second)
    }

    @Test("ordinary transactions pass through untouched, in order")
    func nonTransfersUnchanged() throws {
        let ids = [UUID(), UUID(), UUID()]
        let rows = try ids.map { try transaction(id: $0, amountE4: -1000, account: "Checking") }

        let entries = TransactionEntry.collapsingTransfers(rows)

        #expect(entries.map { $0.transaction.transactionId } == ids)
        #expect(entries.allSatisfy { $0.counterpart == nil })
    }
}
