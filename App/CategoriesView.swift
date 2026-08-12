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

    @State private var store = DataStore<PublicSchema.CategoriesSelect>(cacheKey: "categories")
    @State private var isAddingCategory = false
    @State private var editingCategoryId: UUID?
    @State private var deleteCandidate: PublicSchema.CategoriesSelect?
    @State private var deleteTransactionCount = 0
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
            Color(.systemGroupedBackground).ignoresSafeArea()

            if store.isLoading {
                ProgressView()
            } else {
                List {
                    Section("Expense") {
                        ForEach(expenseCategories, id: \.id) { category in
                            categoryRow(category)
                        }
                    }
                    Section("Income") {
                        ForEach(incomeCategories, id: \.id) { category in
                            categoryRow(category)
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
            CategoryFormView(session: session) {
                session.refresh.bump()
            }
        }
        .sheet(item: $editingCategoryId.map(EditingCategoryId.init)) { wrapped in
            if let category = categories.first(where: { $0.id == wrapped.id }) {
                CategoryFormView(session: session, mode: .edit(category)) {
                    session.refresh.bump()
                }
            }
        }
        .alert(
            "Delete \"\(deleteCandidate?.name ?? "")\"?",
            isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }),
            presenting: deleteCandidate
        ) { category in
            Button("Delete", role: .destructive) {
                Task { await performDelete(category) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(
                deleteTransactionCount > 0
                    ? "\(deleteTransactionCount) transaction"
                        + "\(deleteTransactionCount == 1 ? "" : "s") will move to Other."
                    : "This category has no transactions."
            )
        }
        .task { store.restore(from: session.payloadCache) }
        .task(id: session.refresh.token) { await load() }
    }

    @ViewBuilder
    private func categoryRow(_ category: PublicSchema.CategoriesSelect) -> some View {
        CategoryRow(category: category)
            .contentShape(Rectangle())
            .onTapGesture { editingCategoryId = category.id }
            .swipeActions(edge: .trailing) {
                if !category.isDefault && category.systemKey == nil {
                    Button(role: .destructive) {
                        Task { await confirmDelete(category) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
    }

    private func load() async {
        await store.load(
            { try await CategoryRepository.fetchAll(client: session.client) },
            cache: session.payloadCache
        )
    }

    /// Reads a live transaction count before showing the warning — offline,
    /// this throws and surfaces the existing "you appear to be offline"
    /// message rather than presenting a stale or missing count, which is
    /// exactly why category deletion is never routed through the outbox
    /// (see CategoryRepository.deleteWithReassign's own header comment).
    private func confirmDelete(_ category: PublicSchema.CategoriesSelect) async {
        deleteErrorMessage = nil
        do {
            deleteTransactionCount = try await CategoryRepository.transactionCount(
                client: session.client, categoryId: category.id
            )
            deleteCandidate = category
        } catch {
            deleteErrorMessage = UserFacingError.describe(error)
        }
    }

    private func performDelete(_ category: PublicSchema.CategoriesSelect) async {
        deleteErrorMessage = nil
        do {
            try await CategoryRepository.deleteWithReassign(client: session.client, categoryId: category.id)
            session.refresh.bump()
        } catch {
            deleteErrorMessage = UserFacingError.describe(error)
        }
        deleteCandidate = nil
    }
}

/// `.sheet(item:)` needs an `Identifiable`; a bare `UUID?` binding isn't
/// one — same wrapper AccountsListView already uses for the identical
/// reason.
private struct EditingCategoryId: Identifiable {
    let id: UUID
}

private extension Binding where Value == UUID? {
    func map(_ transform: @escaping (UUID) -> EditingCategoryId) -> Binding<EditingCategoryId?> {
        Binding<EditingCategoryId?>(
            get: { wrappedValue.map(transform) },
            set: { wrappedValue = $0?.id }
        )
    }
}

private struct CategoryRow: View {
    let category: PublicSchema.CategoriesSelect

    var body: some View {
        HStack {
            Text(category.name)
                .foregroundStyle(Color.primary)
            if category.isDefault {
                Spacer()
                Text("Default")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
        }
    }
}
