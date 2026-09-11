import KeepoCore
import SwiftUI

// Split out of `CategoryMergeSheet.swift` for the project's file-length
// lint — same precedent as `Outbox+Capture.swift` and
// `LocalStore+SchemaMigration.swift`. It is a natural seam rather than an
// arbitrary cut: this is the *answer* to "what is being merged", and the
// sheet is what the owner does about it.

extension CategoryMergeSheet {
    /// What is being merged — an existing pair being edited, or a new merge
    /// starting from one of your unpartnered categories.
    enum Subject: Identifiable {
        case existing(HouseholdMergedCategory)
        case new(HouseholdExtraCategory)

        var id: UUID {
            switch self {
            case .existing(let merged): return merged.groupId
            case .new(let extra): return extra.category.id
            }
        }

        var kind: PublicSchema.CategoryKind {
            switch self {
            case .existing(let merged): return merged.kind
            case .new(let extra): return extra.category.kind
            }
        }

        /// Your own row, which is always the left-hand tile.
        var mine: PublicSchema.CategoriesSelect {
            switch self {
            case .existing(let merged): return merged.mine
            case .new(let extra): return extra.category
            }
        }

        var isExisting: Bool {
            if case .existing = self { return true }
            return false
        }
    }
}
