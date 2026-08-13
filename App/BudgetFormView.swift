import KeepoCore
import SwiftUI

/// Create and edit share one form. Always targets the CURRENT calendar
/// month — no rollover, no historical/future budget creation in v1 (spec:
/// "calendar month, no rollover"). Category is locked once a budget
/// exists; changing which category a budget applies to is delete-and-
/// recreate territory this project doesn't offer any budget deletion for
/// in the first place (no DELETE policy anywhere, schema-wide).
struct BudgetFormView: View {
    let session: SessionStore
    var mode: Mode = .create
    var onSaved: () -> Void

    enum Mode {
        case create
        case edit(PublicSchema.BudgetsSelect)
    }

    @Environment(\.dismiss) private var dismiss

    @State private var categories: [PublicSchema.CategoriesSelect] = []
    @State private var isOverall = false
    @State private var selectedCategoryId: UUID?
    @State private var amountText = ""
    @State private var currency = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var expenseCategories: [PublicSchema.CategoriesSelect] {
        categories.filter { $0.kind == .expense }
    }

    var body: some View {
        NavigationStack {
            Form {
                if isLoading {
                    ProgressView()
                } else {
                    if isEditing {
                        Section("Category") {
                            Text(selectedCategoryName)
                                .foregroundStyle(Color.secondary)
                        }
                    } else {
                        Section {
                            Toggle("Overall (not tied to a category)", isOn: $isOverall)
                        }
                        if !isOverall {
                            Section("Category") {
                                Picker("Category", selection: $selectedCategoryId) {
                                    Text("Select…").tag(UUID?.none)
                                    ForEach(expenseCategories, id: \.id) { category in
                                        Text(category.name).tag(category.id as UUID?)
                                    }
                                }
                            }
                        }
                    }

                    Section("Amount") {
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                    }

                    Section("Currency") {
                        Text(currency).foregroundStyle(Color.secondary)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Budget" : "New Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .disabled(isSaveDisabled)
                }
            }
        }
        .task { await load() }
    }

    private var selectedCategoryName: String {
        guard let selectedCategoryId else { return "Overall" }
        return categories.first { $0.id == selectedCategoryId }?.name ?? "—"
    }

    private var isSaveDisabled: Bool {
        isLoading || isSaving || amountText.isEmpty || (!isOverall && !isEditing && selectedCategoryId == nil)
    }

    private func load() async {
        categories = (try? await session.dbQueue.read { database in try LocalTableQueries.categories(database) }) ?? []
        currency = session.profile?.baseCurrency ?? "USD"

        if case .edit(let budget) = mode {
            selectedCategoryId = budget.categoryId
            isOverall = budget.categoryId == nil
            amountText = AmountFormatter.editableString(budget.amountE4, minorUnit: 2)
            currency = budget.currency
        }
        isLoading = false
    }

    private func save() async {
        guard let amountE4 = AmountParser.parse(amountText), let ownerId = session.profile?.id else {
            errorMessage = "Enter a valid amount."
            return
        }

        isSaving = true
        errorMessage = nil
        do {
            switch mode {
            case .create:
                try await BudgetRepository.create(
                    client: session.client, ownerId: ownerId,
                    categoryId: isOverall ? nil : selectedCategoryId, periodMonth: Date(),
                    amountE4: amountE4, currency: currency
                )
            case .edit(let budget):
                try await BudgetRepository.update(
                    client: session.client, id: budget.id, amountE4: amountE4, currency: currency
                )
            }
            onSaved()
            dismiss()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isSaving = false
    }
}
