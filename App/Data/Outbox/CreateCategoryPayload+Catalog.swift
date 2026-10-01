import Foundation
import KeepoCore

extension CreateCategoryPayload {
    /// One new row per `DefaultCategoryCatalog` key, in the order given —
    /// what onboarding's Categories step commits and what the Categories
    /// tab's suggestions sheet adds.
    ///
    /// A key with no catalogue entry is dropped rather than guessed at —
    /// the only way to hold one is a draft written by a build that knew a
    /// category this one does not, and inventing a row for it would put a
    /// category in the user's list that nothing in the app can describe.
    static func catalog(_ keys: [DefaultCategoryKey], ownerId: UUID) -> [CreateCategoryPayload] {
        keys.compactMap(DefaultCategoryCatalog.category(for:)).map { category in
            CreateCategoryPayload(
                id: UUID(), ownerId: ownerId, kind: category.kind,
                name: category.name, icon: category.icon, color: category.color
            )
        }
    }
}
