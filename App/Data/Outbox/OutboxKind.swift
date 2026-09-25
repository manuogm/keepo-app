/// The set of writes `Outbox` can queue and replay. Kept in its own file
/// (not `Outbox.swift`) purely to keep that file under the project's
/// file-length lint threshold — same precedent as `Outbox+AccountsCategories.swift`.
enum OutboxKind: String {
    case createTransaction, createTransfer, updateTransaction, updateTransfer, deleteTransaction, deleteTransfer
    case captureTransaction
    case createAccount, updateAccount, setAccountBalance, archiveAccount, createCategory, updateCategory
    case reorderAccounts, setAccountKind
    case renameCardMapping, unmapCard, mapCard
    case confirmCaptureTransaction
    case reviewCapture
    case createTag, updateTag, deleteTag, setTransactionTag

    /// A write that brings its row into existence on the server. Anything
    /// queued for the same row after one of these depends on it having
    /// landed first, which is why `Outbox.enqueue` never lets a later write
    /// overwrite one — see that function.
    var createsRow: Bool {
        switch self {
        case .createTransaction, .createTransfer, .captureTransaction, .createAccount, .createCategory, .createTag:
            return true
        default:
            return false
        }
    }
}
