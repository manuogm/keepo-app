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
                openingBalanceE4: payload.openingBalanceE4
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
            subtype: payload.subtype, openingBalanceE4: payload.openingBalanceE4,
            includeInTotal: payload.includeInTotal, countsTowardFi: payload.countsTowardFi
        )
        switch result {
        case .saved: return true
        case .conflict: return false
        }
    }

    public func setAccountBalance(_ payload: SetAccountBalancePayload) async throws -> Bool {
        let result = try await AccountRepository.setBalance(
            client: client, accountId: payload.accountId, newBalanceE4: payload.newBalanceE4,
            expectedVersion: payload.expectedVersion, id: payload.id
        )
        return !result.conflict
    }

    public func createCategory(_ payload: CreateCategoryPayload) async throws {
        do {
            try await CategoryRepository.create(
                client: client, id: payload.id, ownerId: payload.ownerId, kind: payload.kind,
                name: payload.name, icon: payload.icon, color: payload.color
            )
        } catch {
            if Self.isDuplicateKey(error) { return }
            throw error
        }
    }

    public func updateCategory(_ payload: UpdateCategoryPayload) async throws {
        try await CategoryRepository.update(
            client: client, categoryId: payload.id, name: payload.name, icon: payload.icon, color: payload.color
        )
    }
}

// MARK: - Outbox

extension Outbox {
    @discardableResult
    public func submitCreateAccount(_ payload: CreateAccountPayload) async -> OutboxSubmitResult {
        applyLocally { try OutboxLocalWrite.createAccount(payload, in: $0) }
        return await attempt(id: payload.id, kind: .createAccount, payload: payload) {
            try await self.sender.createAccount(payload)
            return true
        }
    }

    @discardableResult
    public func submitUpdateAccount(_ payload: UpdateAccountPayload) async -> OutboxSubmitResult {
        applyLocally { try OutboxLocalWrite.updateAccount(payload, in: $0) }
        return await attempt(
            id: payload.id, kind: .updateAccount, payload: payload, expectedVersion: payload.expectedVersion
        ) {
            try await self.sender.updateAccount(payload)
        }
    }

    /// `id` is the adjustment-transaction/snapshot id, freshly generated
    /// per edit — two balance edits made offline before either syncs are
    /// deliberately NOT collapsed into one queued item the way an edit to
    /// the same row normally is. Each queues and applies its own gap
    /// against whatever the account's true balance is when it finally
    /// runs, in order; the net result still lands on the last-entered
    /// value, just via two adjustment transactions instead of one.
    @discardableResult
    public func submitSetAccountBalance(_ payload: SetAccountBalancePayload) async -> OutboxSubmitResult {
        applyLocally { try OutboxLocalWrite.setAccountBalance(payload, in: $0) }
        return await attempt(id: payload.id, kind: .setAccountBalance, payload: payload) {
            try await self.sender.setAccountBalance(payload)
        }
    }

    @discardableResult
    public func submitCreateCategory(_ payload: CreateCategoryPayload) async -> OutboxSubmitResult {
        applyLocally { try OutboxLocalWrite.createCategory(payload, in: $0) }
        return await attempt(id: payload.id, kind: .createCategory, payload: payload) {
            try await self.sender.createCategory(payload)
            return true
        }
    }

    @discardableResult
    public func submitUpdateCategory(_ payload: UpdateCategoryPayload) async -> OutboxSubmitResult {
        applyLocally { try OutboxLocalWrite.updateCategory(payload, in: $0) }
        return await attempt(id: payload.id, kind: .updateCategory, payload: payload) {
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
        case .setAccountBalance:
            return try await sender.setAccountBalance(decoder.decode(SetAccountBalancePayload.self, from: data))
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
