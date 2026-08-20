import KeepoCore
import SwiftUI

/// One component for all three transaction kinds (CLAUDE.md's reuse
/// principle), for both create and edit.
///
/// Rebuilt from a labelled `Form` into a kind tab bar over a single card.
/// The old version had seven `Section` headers ("Account", "Category",
/// "Amount", "Date", "Notes", ...) for seven controls that each already say
/// what they are; worse, the two structurally different things on the screen
/// — what the money did, and everything else about the entry — were shown as
/// one undifferentiated list of rows. `TransactionDetailCard` now owns the
/// first, and this view owns the second.
struct TransactionFormView: View {
    let session: SessionStore
    /// `.create` for a new transaction; `.edit` pre-fills every field from
    /// an existing row (plus its sibling leg, for a transfer) and locks the
    /// kind — changing kind is delete-and-recreate, never an in-place edit
    /// (app-architecture.md §2).
    var mode: Mode = .create
    var onSaved: () -> Void

    enum Mode {
        case create
        case edit(PublicSchema.TransactionsWithDetailsSelect, sibling: PublicSchema.TransactionsWithDetailsSelect?)
    }

    enum Kind: String, CaseIterable, Identifiable {
        case expense = "Expense"
        case income = "Income"
        case transfer = "Transfer"

        var id: String { rawValue }
    }

    // Not `private` — read from TransactionFormView+Delete.swift, an
    // extension in a different file (kept there purely for file-length).
    @Environment(\.dismiss) var dismiss

    @State var kind: Kind = .expense
    @State var accounts: [LocalAccountRow] = []
    @State var categories: [PublicSchema.CategoriesSelect] = []

    @State var selectedAccountId: UUID?
    @State var selectedCategoryId: UUID?
    @State var amountText = ""
    @State var occurredAt = Date()
    @State var merchantRaw: String?
    @State var notes = ""

    @State var selectedToAccountId: UUID?
    @State var receivedAmountText = ""

    // Edit-mode versions the save call sends back for lost-update detection.
    @State var editingId: UUID?
    @State var editingFromVersion: Int?
    @State var editingToVersion: Int?
    @State var editingTransferGroupId: UUID?
    @State var editingRecurringRuleId: UUID?
    // created_by (who entered it) differs from the viewer on a shared account.
    @State var addedByHouseholdMember = false

    // Set from the row being reviewed — a pending, captured transaction —
    // so Save both applies any edit and confirms it in one tap, per the
    // Needs Review flow's "review, then it's gone" contract.
    @State var isConfirmingCapture = false
    @State var isPendingReview = false
    @State var isCaptured = false

    @State var isSaving = false
    @State var errorMessage: String?
    @State var divergenceWarning: RateDivergence?
    @State var transferDivergenceConfirmed = false

    @State private var isPickingDate = false
    @State private var isCreatingRecurringRule = false

    var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var fromAccount: LocalAccountRow? {
        accounts.first { $0.id == selectedAccountId }
    }

    var toAccount: LocalAccountRow? {
        accounts.first { $0.id == selectedToAccountId }
    }

    var needsReceivedAmount: Bool {
        guard kind == .transfer, let source = fromAccount, let destination = toAccount else { return false }
        return source.currency != destination.currency
    }

    var categoriesForKind: [PublicSchema.CategoriesSelect] {
        let categoryKind: PublicSchema.CategoryKind = kind == .income ? .income : .expense
        return categories.filter { $0.kind == categoryKind }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                VStack(spacing: 14) {
                    KindTabBar(selection: $kind, title: \.rawValue, isEnabled: !isEditing)
                        .padding(.horizontal, 20)
                        .padding(.top, 4)

                    ScrollView {
                        detailCard
                            .padding(.horizontal, 16)
                            .padding(.bottom, 24)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .navigationTitle(isEditing ? "Edit \(kind.rawValue)" : "New \(kind.rawValue)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: { Image(systemName: "checkmark") }
                        .disabled(isSaveDisabled)
                }
            }
            .transferDivergenceAlert($divergenceWarning) {
                transferDivergenceConfirmed = true
                Task { await save() }
            }
            .sheet(isPresented: $isPickingDate) { datePickerSheet }
            .navigationDestination(isPresented: $isCreatingRecurringRule) {
                RecurringRuleFormView(session: session, mode: recurringSeedMode) {
                    session.refresh.bump()
                    dismiss()
                }
            }
        }
        .task { await load() }
    }

    // MARK: - The card

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                datePill
                Spacer()
                if isPendingReview {
                    PendingBadge()
                }
            }

            TransactionDetailCard(
                fromAccountId: $selectedAccountId,
                toAccountId: $selectedToAccountId,
                categoryId: $selectedCategoryId,
                amountText: $amountText,
                receivedAmountText: $receivedAmountText,
                accounts: accounts,
                categories: categoriesForKind,
                isTransfer: kind == .transfer,
                needsReceivedAmount: needsReceivedAmount
            )

            // Every kind, including transfers, since migration
            // 20260904100000 gave `create_transfer`/`update_transfer` a
            // `p_notes` that writes to both legs.
            TextField("Add a note…", text: $notes, axis: .vertical)
                .font(.subheadline)
                .lineLimit(1...4)

            recurringLine

            if addedByHouseholdMember {
                Text("Added by your household member")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            // Standard practice whenever a swipe-action exists elsewhere
            // for the same object (the list's swipe-to-delete) — not
            // every user discovers the gesture.
            if isEditing {
                DestructiveActionButton(title: "Delete", isEnabled: !isSaving) {
                    Task { await deleteTransaction() }
                }
                .padding(.top, 4)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
    }

    /// Outlined rather than filled: it sits on the card's own surface, and a
    /// second filled capsule there competed with the amount for weight. The
    /// two most recent days get their names instead of their dates — "Today"
    /// is what the user is actually thinking, and it is also the value they
    /// most need to be able to confirm at a glance.
    private var datePill: some View {
        Button {
            isPickingDate = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.caption)
                Text(dateLabel)
                    .font(.subheadline)
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .overlay {
                Capsule().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.pressableCard)
    }

    private var dateLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(occurredAt) { return "Today" }
        if calendar.isDateInYesterday(occurredAt) { return "Yesterday" }
        return occurredAt.formatted(date: .abbreviated, time: .omitted)
    }

    /// One grey line that answers "where did this come from, and can it
    /// happen again on its own?" — three states, never two at once:
    /// captured rows say so and stop there (a capture cannot be turned into
    /// a rule, it already happened); a row that is already an instance of a
    /// rule says so; anything else offers to become one.
    @ViewBuilder
    private var recurringLine: some View {
        if isCaptured {
            recurringLabel("Automatically captured", icon: "cpu")
        } else if editingRecurringRuleId != nil {
            recurringLabel("Recurring", icon: "arrow.trianglehead.2.clockwise.rotate.90")
        } else if kind != .transfer {
            // `recurring_rules` has a single account_id/category_id pair
            // (app-architecture.md §3) — there is no shape in the schema for
            // a recurring transfer, so offering the button would push to a
            // form that cannot represent what was asked for.
            Button {
                isCreatingRecurringRule = true
            } label: {
                // Filled only in this branch. The other two states are
                // statements of fact, not buttons — giving all three the same
                // pill would promise a tap that two of them do not honour.
                recurringLabel("Make recurring", icon: "arrow.trianglehead.2.clockwise.rotate.90")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color(.tertiarySystemGroupedBackground), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.pressableCard)
        }
    }

    private func recurringLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(title)
        }
        .font(.caption)
        .foregroundStyle(Color.secondary)
    }

    private var datePickerSheet: some View {
        NavigationStack {
            DatePicker("Date", selection: $occurredAt, displayedComponents: [.date])
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("Date")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { isPickingDate = false }.fontWeight(.semibold)
                    }
                }
        }
        .presentationDetents([.medium])
    }

    /// Seeds the recurring-rule form from what is already on screen, so
    /// "make this happen every month" does not mean retyping the amount,
    /// account and category that are right there.
    private var recurringSeedMode: RecurringRuleFormView.Mode {
        .createSeeded(
            accountId: selectedAccountId,
            categoryId: selectedCategoryId,
            amountText: amountText,
            isIncome: kind == .income,
            startingOn: occurredAt
        )
    }

    var isSaveDisabled: Bool {
        if isSaving || selectedAccountId == nil || amountText.isEmpty { return true }
        if kind == .transfer {
            if selectedToAccountId == nil { return true }
            if needsReceivedAmount && receivedAmountText.isEmpty { return true }
        } else if selectedCategoryId == nil {
            return true
        }
        return false
    }
}
