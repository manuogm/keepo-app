import Foundation
import KeepoCore

// Accounts and categories going through the outbox — split out of
// Outbox.swift purely to keep that file under the project's file-length
// lint threshold. Delete is deliberately absent from both: see
// `CreateAccountPayload`/`CreateCategoryPayload`'s own header comments.

// MARK: - LiveOutboxSender

extension LiveOutboxSender {
    public func createAccount(_ payload: CreateAccountPayload) async throws {
        do {
            try await AccountRepository.create(
                client: client, id: payload.id, ownerId: payload.ownerId, kind: payload.kind,
                subtype: payload.subtype, name: payload.name, currency: payload.currency,
                openingBalance: payload.openingBalance
            )
        } catch {
            // A retried create that already landed hits `accounts`' primary
            // key. Known, accepted gap for a valuation account specifically:
            // if the very first attempt inserted the account row but never
            // got a response before its first snapshot insert, that retry
            // (now swallowed here) never gets a second chance to write the
            // snapshot either — the same class of two-statement partial-
            // success risk `CreateTransferPayload` already carries and
            // isn't compensated for there either.
            if Self.isDuplicateKey(error) { return }
            throw error
        }
    }

    public func updateAccount(_ payload: UpdateAccountPayload) async throws -> Bool {
        let result = try await AccountRepository.update(
            client: client, id: payload.id, expectedVersion: payload.expectedVersion, name: payload.name,
            subtype: payload.subtype, openingBalance: payload.openingBalance,
            includeInTotal: payload.includeInTotal, countsTowardFi: payload.countsTowardFi
        )
        switch result {
        case .saved: return true
        case .conflict: return false
        }
    }

    public func createCategory(_ payload: CreateCategoryPayload) async throws {
        do {
            try await CategoryRepository.create(
                client: client, id: payload.id, ownerId: payload.ownerId, kind: payload.kind, name: payload.name
            )
        } catch {
            if Self.isDuplicateKey(error) { return }
            throw error
        }
    }

    public func updateCategory(_ payload: UpdateCategoryPayload) async throws {
        try await CategoryRepository.rename(client: client, categoryId: payload.id, name: payload.name)
    }
}

// MARK: - Outbox

extension Outbox {
    @discardableResult
    public func submitCreateAccount(_ payload: CreateAccountPayload) async -> OutboxSubmitResult {
        await attempt(id: payload.id, kind: .createAccount, payload: payload) {
            try await self.sender.createAccount(payload)
            return true
        }
    }

    @discardableResult
    public func submitUpdateAccount(_ payload: UpdateAccountPayload) async -> OutboxSubmitResult {
        await attempt(
            id: payload.id, kind: .updateAccount, payload: payload, expectedVersion: payload.expectedVersion
        ) {
            try await self.sender.updateAccount(payload)
        }
    }

    @discardableResult
    public func submitCreateCategory(_ payload: CreateCategoryPayload) async -> OutboxSubmitResult {
        await attempt(id: payload.id, kind: .createCategory, payload: payload) {
            try await self.sender.createCategory(payload)
            return true
        }
    }

    @discardableResult
    public func submitUpdateCategory(_ payload: UpdateCategoryPayload) async -> OutboxSubmitResult {
        await attempt(id: payload.id, kind: .updateCategory, payload: payload) {
            try await self.sender.updateCategory(payload)
            return true
        }
    }

    /// Called only for the four cases `replay(_:)` delegates here — the
    /// `default` branch is unreachable in practice, kept only because a
    /// non-exhaustive switch over `OutboxKind` isn't allowed.
    func replayAccountOrCategory(_ kind: OutboxKind, data: Data) async throws -> Bool {
        switch kind {
        case .createAccount:
            try await sender.createAccount(decoder.decode(CreateAccountPayload.self, from: data))
            return true
        case .updateAccount:
            return try await sender.updateAccount(decoder.decode(UpdateAccountPayload.self, from: data))
        case .createCategory:
            try await sender.createCategory(decoder.decode(CreateCategoryPayload.self, from: data))
            return true
        case .updateCategory:
            try await sender.updateCategory(decoder.decode(UpdateCategoryPayload.self, from: data))
            return true
        default:
            return true
        }
    }
}
