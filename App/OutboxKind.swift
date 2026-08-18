/// The set of writes `Outbox` can queue and replay. Kept in its own file
/// (not `Outbox.swift`) purely to keep that file under the project's
/// file-length lint threshold — same precedent as `Outbox+AccountsCategories.swift`.
enum OutboxKind: String {
    case createTransaction, createTransfer, updateTransaction, updateTransfer, deleteTransaction, deleteTransfer
    case captureTransaction
    case createAccount, updateAccount, setAccountBalance, archiveAccount, createCategory, updateCategory
    case renameCardMapping, unmapCard, mapCard
    case confirmCaptureTransaction
    case reviewCapture
}
