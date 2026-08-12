import KeepoCore
import SwiftUI

/// One inbox, one renderer switching on `item.kind` — `needs_review`'s
/// stable column contract (kind, item_id, account_id, occurred_at, title,
/// subtitle, amount, currency) means a later phase's new branch (Phase
/// 12/14/18/19) needs no change here at all, only a new `case` in
/// `NeedsReviewRow`'s icon/action switch.
struct NeedsReviewView: View {
    let session: SessionStore

    @State private var store = DataStore<PublicSchema.NeedsReviewSelect>()
    @State private var currencyMinorUnits: [String: Int] = [:]
    @State private var actionErrorMessage: String?
    @State private var editingTransaction: PublicSchema.TransactionsWithDetailsSelect?
    @State private var showEditingTransaction = false
    @State private var mappingCard: PublicSchema.NeedsReviewSelect?
    @State private var showCardMapping = false

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            if store.isLoading {
                ProgressView()
            } else if displayItems.isEmpty {
                Text("Nothing needs review")
                    .foregroundStyle(Color.secondary)
            } else {
                List {
                    ForEach(displayItems, id: \.itemId) { item in
                        row(item)
                    }
                }
                .scrollContentBackground(.hidden)
                .refreshable { await load() }
            }

            if let errorMessage = store.errorMessage ?? actionErrorMessage {
                VStack {
                    Spacer()
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                }
            }
        }
        .navigationTitle("Needs Review")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: session.refresh.token) { await load() }
        .navigationDestination(isPresented: $showEditingTransaction) {
            if let editingTransaction {
                TransactionFormView(session: session, mode: .edit(editingTransaction, sibling: nil)) {
                    session.refresh.bump()
                }
            }
        }
        .sheet(isPresented: $showCardMapping) {
            if let mappingCard {
                MapCardSheet(session: session, item: mappingCard) {
                    session.refresh.bump()
                }
            }
        }
    }

    private var displayItems: [PublicSchema.NeedsReviewSelect] {
        store.items.filter { $0.kind != "reconciliation_gap" }
    }

    @ViewBuilder
    private func row(_ item: PublicSchema.NeedsReviewSelect) -> some View {
        Group {
            if item.kind == "pending_capture" {
                Button {
                    Task { await openForReview(item) }
                } label: {
                    NeedsReviewRow(item: item, minorUnit: minorUnit(for: item.currency))
                }
                .buttonStyle(.plain)
            } else if item.kind == "ambiguous_card" {
                Button {
                    mappingCard = item
                    showCardMapping = true
                } label: {
                    NeedsReviewRow(item: item, minorUnit: minorUnit(for: item.currency))
                }
                .buttonStyle(.plain)
            } else {
                NeedsReviewRow(item: item, minorUnit: minorUnit(for: item.currency))
            }
        }
        .swipeActions(edge: .trailing) { trailingActions(item) }
        .swipeActions(edge: .leading) { leadingActions(item) }
    }

    @ViewBuilder
    private func trailingActions(_ item: PublicSchema.NeedsReviewSelect) -> some View {
        if item.kind == "sync_conflict" {
            Button("Resolve") {
                Task { await resolve(item) }
            }
            .tint(Color.primary)
        } else if item.kind == "pending_capture" {
            Button("Confirm") {
                Task { await confirmCapture(item) }
            }
            .tint(Color.primary)
        } else if item.kind == "csv_import_candidate" {
            Button("Accept") {
                Task { await acceptImportCandidate(item) }
            }
            .tint(Color.primary)
        }
    }

    @ViewBuilder
    private func leadingActions(_ item: PublicSchema.NeedsReviewSelect) -> some View {
        if item.kind == "csv_import_candidate" {
            Button("Reject", role: .destructive) {
                Task { await rejectImportCandidate(item) }
            }
        }
    }

    private func minorUnit(for currencyCode: String?) -> Int {
        guard let currencyCode else { return 2 }
        return currencyMinorUnits[currencyCode] ?? 2
    }

    private func load() async {
        if currencyMinorUnits.isEmpty {
            let currencies = await CurrencyCache.fetchAll(session: session)
            currencyMinorUnits = Dictionary(uniqueKeysWithValues: currencies.map { ($0.code, Int($0.minorUnit)) })
        }
        await store.load { try await NeedsReviewRepository.fetchAll(client: session.client) }
    }

    private func resolve(_ item: PublicSchema.NeedsReviewSelect) async {
        guard let id = item.itemId else { return }
        actionErrorMessage = nil
        do {
            try await NeedsReviewRepository.resolveSyncConflict(client: session.client, id: id)
            session.refresh.bump()
        } catch {
            actionErrorMessage = UserFacingError.describe(error)
        }
    }

    /// The review screen is `TransactionFormView` in edit mode, not a
    /// bespoke capture-review screen (app-architecture.md) — this only
    /// fetches the one row `needs_review` doesn't carry in full.
    private func openForReview(_ item: PublicSchema.NeedsReviewSelect) async {
        guard let id = item.itemId else { return }
        actionErrorMessage = nil
        do {
            guard let transaction = try await TransactionRepository.fetchOne(client: session.client, id: id) else {
                return
            }
            editingTransaction = transaction
            showEditingTransaction = true
        } catch {
            actionErrorMessage = UserFacingError.describe(error)
        }
    }

    /// Confirming only ever flips `status` — any field edit goes through
    /// `openForReview`'s normal transaction-edit path first. Needs the
    /// row's current version, which `needs_review` doesn't carry, hence
    /// the extra fetch.
    private func confirmCapture(_ item: PublicSchema.NeedsReviewSelect) async {
        guard let id = item.itemId else { return }
        actionErrorMessage = nil
        do {
            guard let transaction = try await TransactionRepository.fetchOne(client: session.client, id: id),
                  let version = transaction.version else { return }
            _ = try await CaptureRepository.confirmCapture(
                client: session.client, id: id, expectedVersion: Int(version)
            )
            session.refresh.bump()
        } catch {
            actionErrorMessage = UserFacingError.describe(error)
        }
    }

    private func acceptImportCandidate(_ item: PublicSchema.NeedsReviewSelect) async {
        guard let id = item.itemId else { return }
        actionErrorMessage = nil
        do {
            try await ImportRepository.accept(client: session.client, id: id)
            session.refresh.bump()
        } catch {
            actionErrorMessage = UserFacingError.describe(error)
        }
    }

    private func rejectImportCandidate(_ item: PublicSchema.NeedsReviewSelect) async {
        guard let id = item.itemId else { return }
        actionErrorMessage = nil
        do {
            try await ImportRepository.reject(client: session.client, id: id)
            session.refresh.bump()
        } catch {
            actionErrorMessage = UserFacingError.describe(error)
        }
    }
}

/// Resolves an `ambiguous_card` item — `item.subtitle` carries the raw
/// `card_identifier` (see migration 20260807160000's comment on why it's
/// there and not parsed out of `title`). Only ledger (spendable) accounts
/// are offered — `map_card` itself refuses anything else.
struct MapCardSheet: View {
    let session: SessionStore
    let item: PublicSchema.NeedsReviewSelect
    let onMapped: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var accounts: [PublicSchema.AccountsWithBalancesSelect] = []
    @State private var selectedAccountId: UUID?
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if let cardIdentifier = item.subtitle {
                    Section("Card") {
                        Text(cardIdentifier)
                    }
                }
                Section("Route charges to") {
                    Picker("Account", selection: $selectedAccountId) {
                        Text("Choose an account").tag(UUID?.none)
                        ForEach(ledgerAccounts, id: \.accountId) { account in
                            Text(account.name ?? "—").tag(account.accountId)
                        }
                    }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("Map Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await mapCard() } } label: { Image(systemName: "checkmark") }
                        .disabled(selectedAccountId == nil || isSaving)
                }
            }
            .task {
                accounts = (try? await AccountRepository.fetchAllWithBalances(client: session.client)) ?? []
            }
        }
    }

    private var ledgerAccounts: [PublicSchema.AccountsWithBalancesSelect] {
        accounts.filter { $0.kind == .ledger && $0.archivedAt == nil }
    }

    private func mapCard() async {
        guard let selectedAccountId, let cardIdentifier = item.subtitle else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await CaptureRepository.mapCard(
                client: session.client, cardIdentifier: cardIdentifier, accountId: selectedAccountId
            )
            onMapped()
            dismiss()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
    }
}

struct NeedsReviewRow: View {
    let item: PublicSchema.NeedsReviewSelect
    let minorUnit: Int

    var body: some View {
        HStack {
            Image(systemName: iconName)
                .foregroundStyle(Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title ?? "—")
                    .foregroundStyle(Color.primary)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }
            Spacer()
            if let amount = item.amount, let currencyCode = item.currency {
                Text(MoneyFormatter.format(amount, currency: CurrencyInfo(code: currencyCode, minorUnit: minorUnit)))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary)
            }
        }
    }

    private var iconName: String {
        switch item.kind {
        case "sync_conflict": return "exclamationmark.arrow.triangle.2.circlepath"
        case "pending_capture": return "wallet.pass"
        case "ambiguous_card": return "creditcard.trianglebadge.exclamationmark"
        case "csv_import_candidate": return "doc.text.magnifyingglass"
        default: return "questionmark.circle"
        }
    }
}
