import KeepoCore
import SwiftUI

// The tag row's inputs and its suggestions — split out of
// TransactionFormView.swift for the file-length lint, same precedent as the
// other extensions beside it.

extension TransactionFormView {
    /// Everything the suggestions depend on, plus the refresh token — which
    /// is also what brings a tag created in the tag sheet into `tagsById`,
    /// so the row can draw it the moment the sheet hands it back.
    struct TagContext: Equatable {
        let kind: Kind
        let categoryId: UUID?
        let accountId: UUID?
        let toAccountId: UUID?
        let refresh: Int
    }

    var tagContext: TagContext {
        TagContext(
            kind: kind, categoryId: selectedCategoryId, accountId: selectedAccountId,
            toAccountId: selectedToAccountId, refresh: session.refresh.token
        )
    }

    var tagRow: TagRowModel {
        TagRowModel(
            selectedTagIds: $selectedTagIds,
            tagsById: tagsById,
            suggestedTagIds: suggestedTagIds,
            entry: savedCount,
            onOpenSheet: { isPickingTags = true }
        )
    }

    /// The tags this user put on transactions like this one before, ranked
    /// by `TagSuggestions`: the category and account for an expense or
    /// income, the origin and destination for a transfer. No category yet
    /// means nothing to go on, and no suggestions.
    func loadTagContext() async {
        let context = tagContext
        let loaded = try? await session.dbQueue.read { database in
            let usage: [TagSuggestions.Usage]
            if context.kind == .transfer {
                usage = try LocalTableQueries.transferTagUsage(
                    database, fromAccountId: context.accountId?.uuidString,
                    toAccountId: context.toAccountId?.uuidString
                )
            } else if let categoryId = context.categoryId {
                usage = try LocalTableQueries.tagUsage(
                    database, categoryId: categoryId.uuidString, accountId: context.accountId?.uuidString
                )
            } else {
                usage = []
            }
            return (try LocalTableQueries.tags(database), usage)
        }
        guard let (tags, usage) = loaded else { return }
        tagsById = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0) })
        suggestedTagIds = TagSuggestions.rank(usage).compactMap(UUID.init(uuidString:))
    }
}
