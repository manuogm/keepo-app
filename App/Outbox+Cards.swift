import Foundation
import KeepoCore

// The Account edit sheet's "manage mapped cards" writes, split into their
// own file for the same file-length reasons as Outbox+AccountsCategories.swift
// and Outbox+Capture.swift.

// MARK: - LiveOutboxSender

extension LiveOutboxSender {
    public func renameCardMapping(_ payload: RenameCardMappingPayload) async throws {
        try await CaptureRepository.renameCardMapping(
            client: client, oldCardIdentifier: payload.oldCardIdentifier,
            newCardIdentifier: payload.newCardIdentifier
        )
    }

    public func unmapCard(_ payload: UnmapCardPayload) async throws {
        try await CaptureRepository.unmapCard(client: client, cardIdentifier: payload.cardIdentifier)
    }

    public func mapCard(_ payload: MapCardPayload) async throws {
        try await CaptureRepository.mapCard(
            client: client, cardIdentifier: payload.cardIdentifier, accountId: payload.accountId
        )
    }
}

// MARK: - Outbox

extension Outbox {
    @discardableResult
    public func submitRenameCardMapping(_ payload: RenameCardMappingPayload) async -> Task<OutboxSubmitResult, Never> {
        await applyLocally { try OutboxLocalWrite.renameCardMapping(payload, in: $0) }
        return Task {
            await self.attempt(id: payload.id, kind: .renameCardMapping, payload: payload) {
                try await self.sender.renameCardMapping(payload)
                return true
            }
        }
    }

    @discardableResult
    public func submitUnmapCard(_ payload: UnmapCardPayload) async -> Task<OutboxSubmitResult, Never> {
        await applyLocally { try OutboxLocalWrite.unmapCard(payload, in: $0) }
        return Task {
            await self.attempt(id: payload.id, kind: .unmapCard, payload: payload) {
                try await self.sender.unmapCard(payload)
                return true
            }
        }
    }

    /// Reuses `OutboxLocalWrite.linkCardLocally` — the exact select-then-
    /// update-or-insert `updateTransaction`'s own auto-link already does,
    /// since a manual "Add Card" and an auto-link on review are the same
    /// underlying operation (upsert by owner+card_identifier), just triggered
    /// from a different screen.
    @discardableResult
    public func submitMapCard(_ payload: MapCardPayload) async -> Task<OutboxSubmitResult, Never> {
        await applyLocally {
            try OutboxLocalWrite.linkCardLocally(
                ownerId: payload.ownerId.uuidString, cardIdentifier: payload.cardIdentifier,
                accountId: payload.accountId.uuidString, in: $0
            )
        }
        return Task {
            await self.attempt(id: payload.id, kind: .mapCard, payload: payload) {
                try await self.sender.mapCard(payload)
                return true
            }
        }
    }

    func replayCardMapping(_ kind: OutboxKind, data: Data) async throws -> Bool {
        switch kind {
        case .renameCardMapping:
            try await sender.renameCardMapping(decoder.decode(RenameCardMappingPayload.self, from: data))
            return true
        case .unmapCard:
            try await sender.unmapCard(decoder.decode(UnmapCardPayload.self, from: data))
            return true
        case .mapCard:
            try await sender.mapCard(decoder.decode(MapCardPayload.self, from: data))
            return true
        default:
            return true
        }
    }
}
