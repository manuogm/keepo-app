import Foundation
import KeepoCore

/// A rejected account write, exactly as the RPC received it — the account
/// twin of `AttemptedTransactionWrite`, kept on the conflict row since
/// migration 20261018100000. Before it existed an account conflict recorded
/// nothing, so the sheet had nothing to compare and "Keep My Change" could
/// only re-send the archived flag: a rename, a balance, a type change or a
/// delete was lost whichever button the user pressed.
///
/// The server writes `{"rpc": <name>, ...arguments}`; keys arrive snake_case.
struct AttemptedAccountWrite: Decodable {
    let rpc: String
    let name: String?
    let includeInTotal: Bool?
    let icon: String?
    let color: String?
    let newBalanceE4: Int64?
    let archived: Bool?
    let kind: PublicSchema.AccountKind?
    let cascade: Bool?

    static func decode(_ json: String?) -> AttemptedAccountWrite? {
        guard let data = json?.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(AttemptedAccountWrite.self, from: data)
    }

    var isDelete: Bool { rpc == "delete_account" }

    /// Sends this write again through the call that made it, against the
    /// version the account is at now. Waits for delivery, as "Keep mine"
    /// always has, so the conflict is marked resolved only after the write
    /// it resolves in favour of has been sent (or queued). Returns `false`
    /// when the account's own row is no longer on this device.
    ///
    /// A delete goes straight to the server, as it does from the Archived
    /// screen — it is online-only by design, so it throws rather than queues.
    @MainActor
    func replay(account: PublicSchema.AccountsSelect, session: SessionStore) async throws -> Bool {
        let version = Int(account.version)
        switch rpc {
        case "update_account":
            guard let name, let includeInTotal else { return false }
            _ = await session.outbox.submitUpdateAccount(UpdateAccountPayload(
                id: account.id, expectedVersion: version, name: name, openingBalanceE4: account.openingBalanceE4,
                includeInTotal: includeInTotal, icon: icon ?? account.icon, color: color ?? account.color
            )).value
        case "set_account_balance":
            guard let newBalanceE4 else { return false }
            _ = await session.outbox.submitSetAccountBalance(SetAccountBalancePayload(
                id: UUID(), accountId: account.id, newBalanceE4: newBalanceE4, expectedVersion: version
            )).value
        case "archive_account":
            guard let archived else { return false }
            _ = await session.outbox.submitArchiveAccount(
                ArchiveAccountPayload(id: account.id, expectedVersion: version, archived: archived)
            ).value
        case "set_account_kind":
            guard let kind else { return false }
            _ = await session.outbox.submitSetAccountKind(
                SetAccountKindPayload(id: account.id, expectedVersion: version, kind: kind)
            ).value
        case "delete_account":
            return try await AccountRepository.delete(
                client: session.client, id: account.id, expectedVersion: version, cascade: cascade ?? false
            )
        default:
            return false
        }
        return true
    }
}
