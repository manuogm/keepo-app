import KeepoCore
import SwiftUI

// What the invite carries, put into words — split out of JoinFlowView.swift
// for the project's file-length lint. This is the half of the flow that
// exists to answer "what am I agreeing to", so it reads better on its own
// than buried among the pages that render it.

extension JoinFlowView {
    // MARK: - Preview

    var incomingAccountNames: [String] {
        preview.compactMap(\.accountName)
    }

    var incomingCategoryNames: [String] {
        preview.compactMap(\.categoryName)
    }

    var incomingSummary: String {
        let accountPart = countPhrase(incomingAccountNames.count, "account", "accounts")
        let categoryPart = countPhrase(incomingCategoryNames.count, "category", "categories")
        if incomingAccountNames.isEmpty && incomingCategoryNames.isEmpty {
            return "Nothing yet — they haven't shared anything with this invite."
        }
        return "\(accountPart) and \(categoryPart)."
    }

    var outgoingSummary: String {
        if selectedAccountIds.isEmpty && selectedCategoryIds.isEmpty {
            return "Nothing yet. You can share any time from the Household screen."
        }
        return countPhrase(selectedAccountIds.count, "account", "accounts")
            + " and " + countPhrase(selectedCategoryIds.count, "category", "categories") + "."
    }

    func countPhrase(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    /// The same trimmed, case-insensitive comparison `ensure_category_twin`
    /// makes on the server. Shown here so "these two become one" is something
    /// the user is told rather than something they discover.
    func matchDetail(for category: PublicSchema.CategoriesSelect) -> String? {
        let mine = category.name.trimmingCharacters(in: .whitespaces).lowercased()
        guard incomingCategoryNames.contains(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased() == mine
        }) else { return nil }
        return "Merges with theirs"
    }
}
