import KeepoCore
import SwiftUI

/// Create and edit share one form, mirroring `AccountFormView`. Kind is
/// locked once a category exists, same reasoning as an account's kind/
/// currency being locked on edit: `sign_matches_category_kind` ties every
/// transaction already referencing this category to its current kind, so
/// changing it would invalidate history rather than just this row.
///
/// Edit mode carries the whole row, not just an id — unlike
/// `AccountFormView`, there's no separate "raw row vs. enriched view" split
/// for categories (`CategoriesSelect` already has every field this form
/// needs), so the caller's already-loaded list row is reused directly and
/// no network fetch (and therefore no offline fallback) is needed to open
/// this sheet at all.
struct CategoryFormView: View {
    let session: SessionStore
    var mode: Mode = .create
    var onSaved: () -> Void

    enum Mode {
        case create
        case edit(PublicSchema.CategoriesSelect)
    }

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var kind: PublicSchema.CategoryKind = .expense
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)

                if isEditing {
                    Text(kind == .income ? "Income" : "Expense")
                        .foregroundStyle(Color.secondary)
                } else {
                    Picker("Kind", selection: $kind) {
                        Text("Expense").tag(PublicSchema.CategoryKind.expense)
                        Text("Income").tag(PublicSchema.CategoryKind.income)
                    }
                    .pickerStyle(.segmented)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(isEditing ? "Edit Category" : "New Category")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
        }
        .task { prefill() }
    }

    private func prefill() {
        if case .edit(let category) = mode {
            name = category.name
            kind = category.kind
        }
    }

    /// Goes through `session.outbox`, never `CategoryRepository` directly —
    /// same reasoning as AccountFormView's writes: an offline create/rename
    /// queues instead of erroring.
    private func save() async {
        isSaving = true
        errorMessage = nil
        switch mode {
        case .create:
            guard let userId = session.profile?.id else { return }
            let payload = CreateCategoryPayload(id: UUID(), ownerId: userId, kind: kind, name: name)
            await session.outbox.submitCreateCategory(payload)
        case .edit(let category):
            let payload = UpdateCategoryPayload(id: category.id, name: name)
            await session.outbox.submitUpdateCategory(payload)
        }
        onSaved()
        dismiss()
        isSaving = false
    }
}
