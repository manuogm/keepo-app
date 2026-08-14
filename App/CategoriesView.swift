import KeepoCore
import SwiftUI

/// Square icon+color tiles rather than plain rows — tap opens the edit
/// sheet, which is also where deletion now lives (see CategoryFormView):
/// a `LazyVGrid` tile has no swipe-actions affordance the way a `List` row
/// does, so consolidating delete into the sheet isn't a compromise, it's
/// the natural consequence of the tile layout.
struct CategoriesView: View {
    let session: SessionStore

    private enum KindTab: String, CaseIterable {
        case expense = "Expense"
        case income = "Income"
    }

    @State private var categories: [PublicSchema.CategoriesSelect] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isAddingCategory = false
    @State private var editingCategoryId: UUID?
    @State private var selectedTab: KindTab = .expense

    private var expenseCategories: [PublicSchema.CategoriesSelect] {
        categories.filter { $0.kind == .expense }
    }

    private var incomeCategories: [PublicSchema.CategoriesSelect] {
        categories.filter { $0.kind == .income }
    }

    private var visibleCategories: [PublicSchema.CategoriesSelect] {
        selectedTab == .expense ? expenseCategories : incomeCategories
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                Picker("Kind", selection: $selectedTab) {
                    ForEach(KindTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()

                if isLoading {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(visibleCategories, id: \.id) { category in
                                Button {
                                    editingCategoryId = category.id
                                } label: {
                                    CategoryTile(category: category)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .refreshable { await load() }
                }
            }

            if let errorMessage {
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
        .sheet(item: $editingCategoryId) { id in
            if let category = categories.first(where: { $0.id == id }) {
                CategoryFormView(session: session, mode: .edit(category)) {
                    session.refresh.bump()
                }
            }
        }
        .task(id: session.refresh.token) { await load() }
    }

    private func load() async {
        errorMessage = nil
        do {
            categories = try await session.dbQueue.read { database in try LocalTableQueries.categories(database) }
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isLoading = false
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
                .clipShape(Circle())
            Text(category.name)
                .font(.footnote)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
