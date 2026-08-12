import KeepoCore
import SwiftUI

/// Square icon+color tiles rather than plain rows — tap opens the edit
/// sheet, which is also where deletion now lives (see CategoryFormView):
/// a `LazyVGrid` tile has no swipe-actions affordance the way a `List` row
/// does, so consolidating delete into the sheet isn't a compromise, it's
/// the natural consequence of the tile layout.
struct CategoriesView: View {
    let session: SessionStore

    @State private var store = DataStore<PublicSchema.CategoriesSelect>(cacheKey: "categories")
    @State private var isAddingCategory = false
    @State private var editingCategoryId: UUID?

    private var categories: [PublicSchema.CategoriesSelect] { store.items }

    private var expenseCategories: [PublicSchema.CategoriesSelect] {
        categories.filter { $0.kind == .expense }
    }

    private var incomeCategories: [PublicSchema.CategoriesSelect] {
        categories.filter { $0.kind == .income }
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            if store.isLoading {
                ProgressView()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        categorySection(title: "Expense", categories: expenseCategories)
                        categorySection(title: "Income", categories: incomeCategories)
                    }
                    .padding()
                }
                .refreshable { await load() }
            }

            if let errorMessage = store.errorMessage {
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
        .navigationBarTitleDisplayMode(.inline)
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
        .task { store.restore(from: session.payloadCache) }
        .task(id: session.refresh.token) { await load() }
    }

    @ViewBuilder
    private func categorySection(title: String, categories: [PublicSchema.CategoriesSelect]) -> some View {
        if !categories.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.secondary)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(categories, id: \.id) { category in
                        CategoryTile(category: category)
                            .onTapGesture { editingCategoryId = category.id }
                    }
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

private struct CategoryTile: View {
    let category: PublicSchema.CategoriesSelect

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: category.icon)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Color(hex: category.color))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(category.name)
                .font(.footnote)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
