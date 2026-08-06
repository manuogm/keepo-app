import KeepoCore
import SwiftUI

/// Expense and income sections; the two default "Other" rows have no delete
/// affordance at all — not just a blocked action — matching
/// keepo-v1-feature-spec.md §Transaction Entry & Automation. The DB's
/// prevent_default_category_deletion trigger is the actual enforcement;
/// omitting the swipe action here is the honest UI reflection of that, not
/// a substitute for it.
struct CategoriesView: View {
    let session: SessionStore

    @State private var store = DataStore<PublicSchema.CategoriesSelect>()
    @State private var isAddingCategory = false
    @State private var deleteErrorMessage: String?

    private var categories: [PublicSchema.CategoriesSelect] { store.items }

    private var expenseCategories: [PublicSchema.CategoriesSelect] {
        categories.filter { $0.kind == .expense }
    }

    private var incomeCategories: [PublicSchema.CategoriesSelect] {
        categories.filter { $0.kind == .income }
    }

    var body: some View {
        ZStack {
            Color("BGCanvas").ignoresSafeArea()

            if store.isLoading {
                ProgressView()
            } else {
                List {
                    Section("Expense") {
                        ForEach(expenseCategories, id: \.id) { category in
                            CategoryRow(category: category)
                                .swipeActions(edge: .trailing) {
                                    if !category.isDefault {
                                        Button(role: .destructive) {
                                            Task { await delete(category) }
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                        }
                    }
                    Section("Income") {
                        ForEach(incomeCategories, id: \.id) { category in
                            CategoryRow(category: category)
                                .swipeActions(edge: .trailing) {
                                    if !category.isDefault {
                                        Button(role: .destructive) {
                                            Task { await delete(category) }
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .refreshable { await load() }
            }

            if let errorMessage = store.errorMessage ?? deleteErrorMessage {
                VStack {
                    Spacer()
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                }
            }
        }
        .navigationTitle("Categories")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAddingCategory = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $isAddingCategory) {
            AddCategorySheet(session: session) {
                session.refresh.bump()
            }
        }
        .task(id: session.refresh.token) { await load() }
    }

    private func load() async {
        await store.load { try await CategoryRepository.fetchAll(client: session.client) }
    }

    private func delete(_ category: PublicSchema.CategoriesSelect) async {
        deleteErrorMessage = nil
        do {
            try await CategoryRepository.softDelete(client: session.client, categoryId: category.id)
            session.refresh.bump()
        } catch {
            deleteErrorMessage = String(describing: error)
        }
    }
}

private struct CategoryRow: View {
    let category: PublicSchema.CategoriesSelect

    var body: some View {
        HStack {
            Text(category.name)
                .foregroundStyle(Color("TextPrimary"))
            if category.isDefault {
                Spacer()
                Text("Default")
                    .font(.caption)
                    .foregroundStyle(Color("TextSecondary"))
            }
        }
    }
}

private struct AddCategorySheet: View {
    let session: SessionStore
    var onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: PublicSchema.CategoryKind = .expense
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Kind", selection: $kind) {
                    Text("Expense").tag(PublicSchema.CategoryKind.expense)
                    Text("Income").tag(PublicSchema.CategoryKind.income)
                }
                .pickerStyle(.segmented)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("New Category")
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
    }

    private func save() async {
        guard let userId = session.profile?.id else { return }
        isSaving = true
        errorMessage = nil
        do {
            try await CategoryRepository.create(client: session.client, ownerId: userId, kind: kind, name: name)
            await onSaved()
            dismiss()
        } catch {
            errorMessage = String(describing: error)
        }
        isSaving = false
    }
}
