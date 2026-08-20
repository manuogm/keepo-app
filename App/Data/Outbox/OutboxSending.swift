import Foundation
import KeepoCore

// MARK: - The testable seam

/// Everything the outbox needs to actually deliver a write. `Bool` returns
/// mean applied (`true`)/conflict (`false`) — conflict-as-data, never
/// thrown, exactly like the RPCs themselves (a thrown error here means a
/// real failure — offline, a 5xx, ... — and leaves the item queued).
public protocol OutboxSending: Sendable {
    func createTransaction(_ payload: CreateTransactionPayload) async throws
    func createTransfer(_ payload: CreateTransferPayload) async throws
    func updateTransaction(_ payload: UpdateTransactionPayload) async throws -> Bool
    func updateTransfer(_ payload: UpdateTransferPayload) async throws -> Bool
    func deleteTransaction(_ payload: DeleteTransactionPayload) async throws -> Bool
    func deleteTransfer(_ payload: DeleteTransferPayload) async throws -> Bool
    /// No conflict/applied distinction — a capture is an insert-or-noop
    /// keyed by `externalId`, never an edit of an existing row, and since
    /// migration 20260822100000 the RPC always inserts, so there is no
    /// per-outcome data left for a caller to branch on either.
    func captureTransaction(_ payload: CaptureTransactionPayload) async throws
    func createAccount(_ payload: CreateAccountPayload) async throws
    func updateAccount(_ payload: UpdateAccountPayload) async throws -> Bool
    /// No conflict concept — ordering is last-arrangement-wins by design
    /// (see `ReorderAccountsPayload`'s own header comment).
    func reorderAccounts(_ payload: ReorderAccountsPayload) async throws
    func setAccountKind(_ payload: SetAccountKindPayload) async throws -> Bool
    func setAccountBalance(_ payload: SetAccountBalancePayload) async throws -> Bool
    func archiveAccount(_ payload: ArchiveAccountPayload) async throws -> Bool
    func createCategory(_ payload: CreateCategoryPayload) async throws
    /// No applied/conflict distinction — see `UpdateCategoryPayload`'s own
    /// header comment on why a rename has nothing to conflict against.
    func updateCategory(_ payload: UpdateCategoryPayload) async throws
    /// Neither has a conflict concept — see `RenameCardMappingPayload`/`UnmapCardPayload`'s own comments why.
    func renameCardMapping(_ payload: RenameCardMappingPayload) async throws
    func unmapCard(_ payload: UnmapCardPayload) async throws
    /// No conflict concept either — `map_card` is an upsert keyed by
    /// (owner, card_identifier), same "last write wins" reasoning as rename/unmap.
    func mapCard(_ payload: MapCardPayload) async throws
    func confirmCaptureTransaction(_ payload: ConfirmCaptureTransactionPayload) async throws -> Bool
    func reviewCaptureTransaction(_ payload: ReviewCaptureTransactionPayload) async throws -> Bool
}
