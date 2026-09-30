import KeepoCore
import SwiftUI

// The rule's title — the field, and what typing one does to the category.
// The transaction form's own +Title.swift, aimed at the future: a rule is
// named the way a transaction is, and "Rent" points at the same category
// whether it is being entered once or every month. Nothing here is
// `private`, for the same file-length reason the other extensions give.

extension RecurringRuleFormView {
    /// What every occurrence will be called in the ledger, and — new here —
    /// the thing Keepo reads to guess the category.
    ///
    /// The lookup rides on this view's own `.task(id:)` rather than on the
    /// form's body, which is already near the SwiftUI type checker's budget,
    /// exactly as the transaction form does it.
    var titleField: some View {
        TextField("Title", text: titleBinding)
            .font(AppTheme.Typography.cardTitle)
            .foregroundStyle(AppTheme.Palette.textPrimary)
            .textInputAutocapitalization(.sentences)
            .submitLabel(.done)
            .accessibilityLabel("Title")
            .task(id: TitleLookup(title: title, kind: kind)) { await lookUpTitleCategory() }
    }

    /// Caps at the server's limit as the user types, rather than letting a
    /// save fail on a constraint nobody can see, and records that they typed:
    /// a setter only runs when the control writes, so a prefill — a seeded
    /// rule's carried-over title, an edit's own — can never be mistaken for
    /// the user naming this rule.
    var titleBinding: Binding<String> {
        Binding(
            get: { title },
            set: { typed in
                title = String(typed.prefix(TransactionTitle.maxLength))
                titleEdited = true
            }
        )
    }

    /// The category binding the card writes through. Its setter is the only
    /// place a *tap* on a category reaches, which is what lets a title stop
    /// proposing categories the moment the user has chosen one themselves.
    var userCategoryBinding: Binding<UUID?> {
        Binding(
            get: { selectedCategoryId },
            set: { chosen in
                selectedCategoryId = chosen
                categoryPickedByUser = true
            }
        )
    }

    /// The chips, with the title's match in front of them when there is one.
    var displayedCategorySuggestions: [PublicSchema.CategoriesSelect] {
        CategorySuggestions.prioritizing(
            titleCategoryId.flatMap { id in categoriesForKind.first { $0.id == id } }, in: suggestedCategories
        )
    }

    /// Whether the category on screen is still Keepo's guess rather than a
    /// decision somebody made — and so whether a title may *select* as well
    /// as suggest.
    ///
    /// Only on a rule built from nothing. **"Make recurring" is not that**:
    /// a seeded rule carries the category of the transaction the user was
    /// looking at one screen back, which is a decision they already made and
    /// a better one than a title can offer. Nor is an edit — renaming a
    /// standing rule must not quietly re-file every occurrence it will go on
    /// creating. In both cases the match is still offered as the first chip,
    /// one tap away, and nothing more.
    var categoryIsProvisional: Bool {
        if case .create = mode { return true }
        return false
    }

    /// Asks the title memory what the typed title points at. The wait, the
    /// read and the "is this category even on offer here" check are
    /// `LocalTitleMemory.categoryForTypedTitle`'s, shared with the
    /// transaction form; what is left here is this form's own half.
    ///
    /// A transfer has no category at all, so it asks nothing — the same guard
    /// `refreshCategorySuggestions` makes.
    func lookUpTitleCategory() async {
        guard kind != .transfer, let ownerId = session.profile?.id else {
            titleCategoryId = nil
            return
        }
        let match = await LocalTitleMemory.categoryForTypedTitle(
            title, categoryKind: kind == .income ? .income : .expense, ownerId: ownerId,
            among: categoriesForKind, in: session.dbQueue
        )
        guard !Task.isCancelled else { return }
        titleCategoryId = match
        if let match, categoryIsProvisional, titleEdited, !categoryPickedByUser {
            selectedCategoryId = match
        }
    }

    /// The two inputs the lookup depends on — a kind change asks again,
    /// because "Refund" means something different under Income.
    struct TitleLookup: Equatable {
        let title: String
        let kind: Kind
    }
}
