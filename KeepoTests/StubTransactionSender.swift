import Foundation
import KeepoCore
@testable import Keepo

// StubTransactionSender, split out of OutboxTests.swift purely to keep
// that file under the project's file-length lint threshold.

enum StubSenderError: Error {
    case network
}

final class StubTransactionSender: OutboxSending, @unchecked Sendable {
    var createTransactionResult: Result<Void, Error> = .success(())
    var createTransferResult: Result<Void, Error> = .success(())
    var updateTransactionResult: Result<Bool, Error> = .success(true)
    var updateTransferResult: Result<Bool, Error> = .success(true)
    var deleteTransactionResult: Result<Bool, Error> = .success(true)
    var deleteTransferResult: Result<Bool, Error> = .success(true)
    var captureTransactionResult: Result<Void, Error> = .success(())

    private(set) var lastUpdateTransactionPayload: UpdateTransactionPayload?

    func createTransaction(_ payload: CreateTransactionPayload) async throws {
        try createTransactionResult.get()
    }

    func createTransfer(_ payload: CreateTransferPayload) async throws {
        try createTransferResult.get()
    }

    func updateTransaction(_ payload: UpdateTransactionPayload) async throws -> Bool {
        lastUpdateTransactionPayload = payload
        return try updateTransactionResult.get()
    }

    func updateTransfer(_ payload: UpdateTransferPayload) async throws -> Bool {
        try updateTransferResult.get()
    }

    func deleteTransaction(_ payload: DeleteTransactionPayload) async throws -> Bool {
        try deleteTransactionResult.get()
    }

    func deleteTransfer(_ payload: DeleteTransferPayload) async throws -> Bool {
        try deleteTransferResult.get()
    }

    private(set) var captureTransactionCallCount = 0
    /// Opt-in for `confirmSelfHealsALostCapture` only — every other test
    /// leaves this `false`, so `confirmCaptureTransaction` behaves exactly
    /// as before (governed purely by `confirmCaptureTransactionResult`).
    var requireCaptureBeforeConfirm = false

    func captureTransaction(_ payload: CaptureTransactionPayload) async throws {
        captureTransactionCallCount += 1
        try captureTransactionResult.get()
    }

    var createAccountResult: Result<Void, Error> = .success(())
    var updateAccountResult: Result<Bool, Error> = .success(true)
    var setAccountBalanceResult: Result<Bool, Error> = .success(true)
    var archiveAccountResult: Result<Bool, Error> = .success(true)
    var createCategoryResult: Result<Void, Error> = .success(())
    var updateCategoryResult: Result<Void, Error> = .success(())

    func createAccount(_ payload: CreateAccountPayload) async throws {
        try createAccountResult.get()
    }

    func updateAccount(_ payload: UpdateAccountPayload) async throws -> Bool {
        try updateAccountResult.get()
    }

    func setAccountBalance(_ payload: SetAccountBalancePayload) async throws -> Bool {
        try setAccountBalanceResult.get()
    }

    func archiveAccount(_ payload: ArchiveAccountPayload) async throws -> Bool {
        try archiveAccountResult.get()
    }

    func createCategory(_ payload: CreateCategoryPayload) async throws {
        try createCategoryResult.get()
    }

    func updateCategory(_ payload: UpdateCategoryPayload) async throws {
        try updateCategoryResult.get()
    }

    var renameCardMappingResult: Result<Void, Error> = .success(())
    var unmapCardResult: Result<Void, Error> = .success(())
    var mapCardResult: Result<Void, Error> = .success(())
    var confirmCaptureTransactionResult: Result<Bool, Error> = .success(true)
    var reviewCaptureTransactionResult: Result<Bool, Error> = .success(true)

    func renameCardMapping(_ payload: RenameCardMappingPayload) async throws {
        try renameCardMappingResult.get()
    }

    func unmapCard(_ payload: UnmapCardPayload) async throws {
        try unmapCardResult.get()
    }

    func mapCard(_ payload: MapCardPayload) async throws {
        try mapCardResult.get()
    }

    func confirmCaptureTransaction(_ payload: ConfirmCaptureTransactionPayload) async throws -> Bool {
        if requireCaptureBeforeConfirm, captureTransactionCallCount == 0 {
            throw StubSenderError.network
        }
        return try confirmCaptureTransactionResult.get()
    }

    func reviewCaptureTransaction(_ payload: ReviewCaptureTransactionPayload) async throws -> Bool {
        try reviewCaptureTransactionResult.get()
    }
}
