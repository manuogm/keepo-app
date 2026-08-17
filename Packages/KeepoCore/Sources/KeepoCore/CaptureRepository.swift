import Foundation
import Supabase

/// The App Intent's one write path, plus the two review actions
/// (`mapCard`/`confirmCaptureTransaction`). Kept alongside
/// `TransactionRepository` rather than folded into it — captures are a
/// distinct write shape (rate-guarded, card-routed, no client-chosen
/// account/category) even though the end result is a row in the same table.
public enum CaptureRepository {
    // swiftlint:disable:next function_parameter_count
    public static func capture(
        client: SupabaseClient,
        id: UUID,
        cardIdentifier: String,
        merchantRaw: String,
        merchantNormalized: String,
        amountE4: Int64,
        occurredAt: Date,
        externalId: String,
        notes: String? = nil
    ) async throws {
        let params = CaptureTransactionParams(
            id: id, cardIdentifier: cardIdentifier, merchantRaw: merchantRaw,
            merchantNormalized: merchantNormalized, amountE4: amountE4,
            occurredAt: PostgresDate.timestampString(occurredAt), externalId: externalId, notes: notes
        )
        // The RPC still returns `(mapped, account_id)`, deliberately not
        // decoded: since migration 20260822100000 it always inserts the
        // transaction, so `mapped` no longer distinguishes "captured" from
        // "not captured" — it only says whether the account was resolved
        // yet, which the row itself already carries and the review form
        // already handles. Nothing branches on it anymore.
        try await client.rpc("capture_transaction", params: params).execute()
    }

    public static func mapCard(client: SupabaseClient, cardIdentifier: String, accountId: UUID) async throws {
        let params = MapCardParams(cardIdentifier: cardIdentifier, accountId: accountId)
        try await client.rpc("map_card", params: params).execute()
    }

    public static func confirmCapture(
        client: SupabaseClient, id: UUID, expectedVersion: Int
    ) async throws -> WriteResult {
        let params = ConfirmCaptureParams(id: id, expectedVersion: expectedVersion)
        let rows: [ConflictRow] = try await client.rpc("confirm_capture_transaction", params: params).execute().value
        return rows.first.map(WriteResult.init) ?? .conflict
    }

    /// The Account edit sheet's "manage mapped cards" actions — resolved by
    /// natural key (owner + the card's current identifier), never by the
    /// mapping's own row id (see `RenameCardMappingPayload`'s own header
    /// comment on why: that id is server-generated and the local mirror
    /// can't reliably know it ahead of a sync pull).
    public static func renameCardMapping(
        client: SupabaseClient, oldCardIdentifier: String, newCardIdentifier: String
    ) async throws {
        let params = RenameCardMappingParams(oldCardIdentifier: oldCardIdentifier, newCardIdentifier: newCardIdentifier)
        try await client.rpc("rename_card_mapping", params: params).execute()
    }

    public static func unmapCard(client: SupabaseClient, cardIdentifier: String) async throws {
        try await client.rpc("unmap_card", params: UnmapCardParams(cardIdentifier: cardIdentifier)).execute()
    }
}

private struct CaptureTransactionParams: Encodable {
    let id: UUID
    let cardIdentifier: String
    let merchantRaw: String
    let merchantNormalized: String
    let amountE4: Int64
    let occurredAt: String
    let externalId: String
    let notes: String?
    enum CodingKeys: String, CodingKey {
        case id = "p_id"
        case cardIdentifier = "p_card_identifier"
        case merchantRaw = "p_merchant_raw"
        case merchantNormalized = "p_merchant_normalized"
        case amountE4 = "p_amount_e4"
        case occurredAt = "p_occurred_at"
        case externalId = "p_external_id"
        case notes = "p_notes"
    }
}

private struct MapCardParams: Encodable {
    let cardIdentifier: String
    let accountId: UUID
    enum CodingKeys: String, CodingKey {
        case cardIdentifier = "p_card_identifier"
        case accountId = "p_account_id"
    }
}

private struct ConfirmCaptureParams: Encodable {
    let id: UUID
    let expectedVersion: Int
    enum CodingKeys: String, CodingKey {
        case id = "p_id"
        case expectedVersion = "p_expected_version"
    }
}

private struct RenameCardMappingParams: Encodable {
    let oldCardIdentifier: String
    let newCardIdentifier: String
    enum CodingKeys: String, CodingKey {
        case oldCardIdentifier = "p_old_card_identifier"
        case newCardIdentifier = "p_new_card_identifier"
    }
}

private struct UnmapCardParams: Encodable {
    let cardIdentifier: String
    enum CodingKeys: String, CodingKey {
        case cardIdentifier = "p_card_identifier"
    }
}
