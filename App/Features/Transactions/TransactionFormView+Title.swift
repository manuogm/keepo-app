import KeepoCore
import SwiftUI

// The transaction's title — the field, and what typing one does to the
// category. Split out of TransactionFormView.swift for the project's
// file-length and type-body-length lints, same precedent as
// TransactionFormView+Date.swift. Nothing here is `private`, for that reason.

extension TransactionFormView {
    /// The user's own name for the entry — "Coffee with Beth", "Rent" —
    /// above the account and the amount, because it is what the row will be
    /// called in the ledger.
    ///
    /// **Bare, with no fill behind it.** It sits on the card's own surface
    /// like a heading rather than in a well like a field, which is what it
    /// becomes the moment it has text: the thing the entry is called. The
    /// grey placeholder is the only sign it is editable before it is tapped,
    /// the same way the note field below it works.
    ///
    /// The lookup rides on this view's own `.task(id:)` rather than on the
    /// form's body, which is already close to the type checker's budget
    /// (see `conversionInputs`).
    var titleField: some View {
        TextField("Title", text: titleBinding)
            .font(AppTheme.Typography.cardTitle)
            .foregroundStyle(AppTheme.Palette.textPrimary)
            .textInputAutocapitalization(.sentences)
            .submitLabel(.done)
            .accessibilityLabel("Title")
            .task(id: TitleLookup(title: title, kind: kind)) { await lookUpTitleCategory() }
    }

    /// Caps at the server's limit as the user types, and records that they
    /// typed — a setter only runs when the control writes, so a prefill can
    /// never be mistaken for the user choosing a title (the same device
    /// `chargedAmountEdited` uses).
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
    /// `CategorySuggestionRow` shows three, so the match costs the weakest
    /// habit its seat rather than being one more thing to scroll to.
    var displayedCategorySuggestions: [PublicSchema.CategoriesSelect] {
        guard let id = titleCategoryId, let match = categoriesForKind.first(where: { $0.id == id }) else {
            return suggestedCategories
        }
        return [match] + suggestedCategories.filter { $0.id != id }
    }

    /// Whether the category on screen is still Keepo's guess rather than a
    /// decision somebody made: always on a new entry, and on a capture being
    /// reviewed, whose category was resolved with nobody watching. Never on
    /// an ordinary edit — retitling a transaction must not quietly re-file
    /// it; there the match is offered as the first chip and nothing more.
    private var categoryIsProvisional: Bool {
        !isEditing || isConfirmingCapture
    }

    /// Asks the title memory what the typed title points at, a beat after
    /// the typing stops — `.task(id:)` cancels this run the moment the title
    /// changes again, so only the settled title is ever looked up.
    func lookUpTitleCategory() async {
        guard kind != .transfer, let ownerId = session.profile?.id, !title.isEmpty else {
            titleCategoryId = nil
            return
        }
        try? await Task.sleep(for: Self.titleLookupDelay)
        guard !Task.isCancelled else { return }

        let typed = title
        let categoryKind = kind == .income ? "income" : "expense"
        let match = try? await session.dbQueue.read { database in
            try LocalTitleMemory.suggestedCategory(
                forTitle: typed, ownerId: ownerId.uuidString, categoryKind: categoryKind, in: database
            )
        }
        guard !Task.isCancelled else { return }
        let valid = match
            .flatMap(UUID.init(uuidString:))
            .flatMap { id in categoriesForKind.contains { $0.id == id } ? id : nil }
        titleCategoryId = valid
        if let valid, categoryIsProvisional, titleEdited, !categoryPickedByUser {
            selectedCategoryId = valid
        }
    }

    /// Long enough that a word being typed is not looked up letter by
    /// letter, short enough that the category has moved by the time the eye
    /// comes back down to it.
    static let titleLookupDelay: Duration = .milliseconds(350)

    /// The two inputs the lookup depends on — a kind change asks again,
    /// because "Refund" means something different under Income.
    struct TitleLookup: Equatable {
        let title: String
        let kind: Kind
    }
}
