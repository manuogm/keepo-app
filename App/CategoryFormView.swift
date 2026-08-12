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
    @State private var icon = CategoryAppearance.pickerIcons[0]
    @State private var color = Color(hex: CategoryAppearance.randomColor())
    @State private var isSaving = false
    @State private var errorMessage: String?

    @State private var deleteTransactionCount = 0
    @State private var isCheckingDelete = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    /// Locked, not just hidden — the DB's own `prevent_default_category_
    /// deletion` trigger refuses both, this only keeps the UI honest about
    /// what will happen.
    private var isDefaultCategory: Bool {
        if case .edit(let category) = mode { return category.isDefault }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .disabled(isDefaultCategory)

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
                } footer: {
                    if isDefaultCategory {
                        Text("The default category can't be renamed or deleted.")
                    }
                }

                Section("Icon") {
                    iconGrid
                }

                Section("Color") {
                    ColorPicker("Category Color", selection: $color, supportsOpacity: false)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if isEditing && !isDefaultCategory {
                    Section {
                        Button(role: .destructive) {
                            Task { await confirmDelete() }
                        } label: {
                            HStack {
                                Text("Delete Category")
                                Spacer()
                                if isCheckingDelete { ProgressView() }
                            }
                        }
                        .disabled(isCheckingDelete || isDeleting)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Category" : "New Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
            .alert(
                "Delete \"\(name)\"?",
                isPresented: $showDeleteConfirm
            ) {
                Button("Delete", role: .destructive) {
                    Task { await performDelete() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    deleteTransactionCount > 0
                        ? "\(deleteTransactionCount) transaction"
                            + "\(deleteTransactionCount == 1 ? "" : "s") will move to Other."
                        : "This category has no transactions."
                )
            }
        }
        .task { prefill() }
    }

    @ViewBuilder
    private var iconGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
            ForEach(CategoryAppearance.pickerIcons, id: \.self) { candidate in
                Button {
                    icon = candidate
                } label: {
                    Image(systemName: candidate)
                        .font(.title3)
                        .frame(width: 36, height: 36)
                        .foregroundStyle(icon == candidate ? Color.white : Color.primary)
                        .background(icon == candidate ? color : Color(.systemGray5))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private func prefill() {
        if case .edit(let category) = mode {
            name = category.name
            kind = category.kind
            icon = category.icon
            color = Color(hex: category.color)
        } else {
            icon = CategoryAppearance.defaultIcon(forName: "", kind: kind)
        }
    }

    /// Goes through `session.outbox`, never `CategoryRepository` directly —
    /// same reasoning as AccountFormView's writes: an offline create/edit
    /// queues instead of erroring.
    private func save() async {
        isSaving = true
        errorMessage = nil
        let resolvedColor = color.hexString ?? CategoryAppearance.randomColor()
        switch mode {
        case .create:
            guard let userId = session.profile?.id else { return }
            let payload = CreateCategoryPayload(
                id: UUID(), ownerId: userId, kind: kind, name: name, icon: icon, color: resolvedColor
            )
            await session.outbox.submitCreateCategory(payload)
        case .edit(let category):
            let payload = UpdateCategoryPayload(id: category.id, name: name, icon: icon, color: resolvedColor)
            await session.outbox.submitUpdateCategory(payload)
        }
        onSaved()
        dismiss()
        isSaving = false
    }

    /// Reads a live transaction count before showing the warning — offline,
    /// this throws and surfaces the existing "you appear to be offline"
    /// message rather than presenting a stale or missing count, which is
    /// exactly why category deletion is never routed through the outbox
    /// (see CategoryRepository.deleteWithReassign's own header comment).
    private func confirmDelete() async {
        guard case .edit(let category) = mode else { return }
        isCheckingDelete = true
        errorMessage = nil
        do {
            deleteTransactionCount = try await CategoryRepository.transactionCount(
                client: session.client, categoryId: category.id
            )
            showDeleteConfirm = true
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isCheckingDelete = false
    }

    private func performDelete() async {
        guard case .edit(let category) = mode else { return }
        isDeleting = true
        errorMessage = nil
        do {
            try await CategoryRepository.deleteWithReassign(client: session.client, categoryId: category.id)
            onSaved()
            dismiss()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isDeleting = false
    }
}
