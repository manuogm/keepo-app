import Foundation
import KeepoCore
@testable import Keepo

enum StubError: Error { case alwaysFails }

/// Every local-write-through suite needs the same thing from a sender:
/// that it never succeeds, so `Outbox.submit*` always falls through to
/// `.queued` and the assertion can be about what landed in the local
/// mirror, not about delivery.
///
/// This used to be five byte-identical `private` copies, one per test file.
/// They were only noticed when `OutboxSending` gained two methods and all
/// five broke at once — which is the argument for one copy: the protocol is
/// the thing that changes, and it should cost one edit, not five.
final class AlwaysFailingSender: OutboxSending, @unchecked Sendable {
    func createTransaction(_ payload: CreateTransactionPayload) async throws { throw StubError.alwaysFails }
    func createTransfer(_ payload: CreateTransferPayload) async throws { throw StubError.alwaysFails }
    func updateTransaction(_ payload: UpdateTransactionPayload) async throws -> Bool { throw StubError.alwaysFails }
    func updateTransfer(_ payload: UpdateTransferPayload) async throws -> Bool { throw StubError.alwaysFails }
    func deleteTransaction(_ payload: DeleteTransactionPayload) async throws -> Bool { throw StubError.alwaysFails }
    func deleteTransfer(_ payload: DeleteTransferPayload) async throws -> Bool { throw StubError.alwaysFails }
    func captureTransaction(_ payload: CaptureTransactionPayload) async throws { throw StubError.alwaysFails }
    func createAccount(_ payload: CreateAccountPayload) async throws { throw StubError.alwaysFails }
    func updateAccount(_ payload: UpdateAccountPayload) async throws -> Bool { throw StubError.alwaysFails }
    func archiveAccount(_ payload: ArchiveAccountPayload) async throws -> Bool { throw StubError.alwaysFails }
    func setAccountBalance(_ payload: SetAccountBalancePayload) async throws -> Bool { throw StubError.alwaysFails }
    func reorderAccounts(_ payload: ReorderAccountsPayload) async throws { throw StubError.alwaysFails }
    func setAccountKind(_ payload: SetAccountKindPayload) async throws -> Bool { throw StubError.alwaysFails }
    func createCategory(_ payload: CreateCategoryPayload) async throws { throw StubError.alwaysFails }
    func updateCategory(_ payload: UpdateCategoryPayload) async throws { throw StubError.alwaysFails }
    func renameCardMapping(_ payload: RenameCardMappingPayload) async throws { throw StubError.alwaysFails }
    func unmapCard(_ payload: UnmapCardPayload) async throws { throw StubError.alwaysFails }
    func mapCard(_ payload: MapCardPayload) async throws { throw StubError.alwaysFails }
    func confirmCaptureTransaction(_ payload: ConfirmCaptureTransactionPayload) async throws -> Bool {
        throw StubError.alwaysFails
    }
    func reviewCaptureTransaction(_ payload: ReviewCaptureTransactionPayload) async throws -> Bool {
        throw StubError.alwaysFails
    }
}
