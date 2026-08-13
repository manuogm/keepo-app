import Foundation
import Supabase

/// The result of `capture_transaction` — whether the card was already
/// mapped to an account. `mapped = false` means no transaction was written
/// at all (there is nowhere to attach a signed amount); the card's
/// placeholder mapping still landed, and surfaces via `needs_review`'s
/// `ambiguous_card` branch until `mapCard` resolves it.
public struct CaptureResult: Codable, Sendable {
    public let mapped: Bool
    public let accountId: UUID?

    public init(mapped: Bool, accountId: UUID?) {
        self.mapped = mapped
        self.accountId = accountId
    }

    enum CodingKeys: String, CodingKey {
        case mapped
        case accountId = "account_id"
    }
}

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
        externalId: String
    ) async throws -> CaptureResult {
        let params = CaptureTransactionParams(
            id: id, cardIdentifier: cardIdentifier, merchantRaw: merchantRaw,
            merchantNormalized: merchantNormalized, amountE4: amountE4,
            occurredAt: PostgresDate.timestampString(occurredAt), externalId: externalId
        )
        let rows: [CaptureResult] = try await client.rpc("capture_transaction", params: params).execute().value
        guard let result = rows.first else {
            throw CaptureRepositoryError.emptyResponse
        }
        return result
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
}

public enum CaptureRepositoryError: Error {
    case emptyResponse
}

private struct CaptureTransactionParams: Encodable {
    let id: UUID
    let cardIdentifier: String
    let merchantRaw: String
    let merchantNormalized: String
    let amountE4: Int64
    let occurredAt: String
    let externalId: String
    enum CodingKeys: String, CodingKey {
        case id = "p_id"
        case cardIdentifier = "p_card_identifier"
        case merchantRaw = "p_merchant_raw"
        case merchantNormalized = "p_merchant_normalized"
        case amountE4 = "p_amount_e4"
        case occurredAt = "p_occurred_at"
        case externalId = "p_external_id"
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
