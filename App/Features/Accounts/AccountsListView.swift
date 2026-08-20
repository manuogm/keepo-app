import KeepoCore
import SwiftUI

/// UI labels are "Everyday" and "Investments" — the groups still split by
/// `kind`, and each investment row carries its own `InvestmentBadge`, per
/// keepo-v1-feature-spec.md §Accounts & Multi-Currency.
///
/// Reads straight off the local GRDB mirror (Phase L6) — no server round
/// trip, no payload cache, no pending-write overlay. `Outbox`'s optimistic
/// write-through means an offline (or just-submitted online) edit is
/// already in the same tables this screen queries.
///
/// **On the drag model.** All three requested behaviours — reorder within a
/// group, drag Everyday→Investments to convert, drag back to convert
/// back — are one mechanism, not three. The two groups render as a single
/// `ForEach` over a flat `[Item]` in which the group headers are themselves
/// items, so a single `.onMove` sees every drag: an account's kind is
/// simply the kind of the nearest header above it once the move lands, and
/// its position is its index within that run. Mixing `.onMove` for the
/// within-group case with `.draggable`/`.dropDestination` for the
/// across-group case was the obvious alternative and is worse — the two
/// gesture systems fight for the same row, and drop targets cannot express
/// "between these two rows" the way an insertion point does.
///
/// Both headers always render, including for an empty group: an empty
/// Investments section with nothing to drop onto would make the conversion
/// gesture undiscoverable exactly when the user most needs it.
struct AccountsListView: View {
    let session: SessionStore

    /// The two groups are held as ordered arrays, not derived by filtering
    /// on every render: a drag mutates them directly so the row follows the
    /// finger immediately, with the outbox write happening behind that.
    @State var everyday: [LocalAccountRow] = []
    @State var investments: [LocalAccountRow] = []
    @State private var archived: [LocalAccountRow] = []

    @State private var isLoading = true
    @State private var isAddingAccount = false
    @State private var editingAccountId: UUID?
    @State private var actionErrorMessage: String?
    @State private var archiveCandidate: LocalAccountRow?
    @State var isEverydayExpanded = true
    @State var isInvestmentsExpanded = true

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            if isLoading {
                ProgressView()
            } else {
                accountList
            }

            if let actionErrorMessage {
                VStack {
                    Spacer()
                    Text(actionErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                }
            }
        }
        .navigationTitle("Accounts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ScopeSwitcherButton(session: session)
            }
            ToolbarItem(placement: .principal) {
                ScreenTitleBar(title: "Accounts", session: session)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAddingAccount = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $isAddingAccount) {
            AddAccountFlowView(session: session) {
                session.refresh.bump()
            }
        }
        .sheet(item: $editingAccountId) { id in
            AccountFormView(session: session, mode: .edit(id)) {
                session.refresh.bump()
            }
        }
        .task(id: session.refresh.token) { await load() }
        .alert(
            "Archive \"\(archiveCandidate?.name ?? "")\"?",
            isPresented: archiveConfirmationBinding
        ) {
            Button("Archive", role: .destructive) {
                if let archiveCandidate { Task { await setArchived(archiveCandidate, archived: true) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Archiving an account will remove it from your total balance but will not delete "
                    + "the account or the transactions associated."
            )
        }
    }

    /// `.plain` with every row drawing its own background, rather than
    /// `.insetGrouped`. An inset-grouped `List` draws ONE rounded card per
    /// `Section`, and the drag model needs the headers and the accounts in a
    /// single `ForEach` (see this type's header comment) — so the card would
    /// have wrapped the headers too, leaving every account row with square
    /// corners in the middle of it. Styling rows individually also makes each
    /// account read as its own liftable object, which is exactly the
    /// affordance a drag-to-reorder list wants.
    private var accountList: some View {
        List {
            ForEach(items) { item in
                row(for: item)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .onMove { offsets, destination in
                Task { await handleMove(from: offsets, to: destination) }
            }

            if !archived.isEmpty {
                archivedRow
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .moveDisabled(true)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await load() }
    }

    @ViewBuilder
    private func row(for item: Item) -> some View {
        switch item {
        case .header(let kind):
            AccountGroupHeaderRow(
                title: kind == .regular ? "Everyday" : "Investments",
                subtitle: subtotalText(for: accounts(for: kind)),
                isExpanded: kind == .regular ? $isEverydayExpanded : $isInvestmentsExpanded
            )
            .listRowInsets(EdgeInsets(top: 18, leading: 20, bottom: 6, trailing: 20))

        case .account(let row):
            Button {
                editingAccountId = row.id
            } label: {
                AccountRowView(row: row)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16)
                    )
            }
            .buttonStyle(.pressableRow)
            .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
            // Without this the lift preview snapshots the whole row rect —
            // a full-bleed, square-cornered slab that looks nothing like the
            // card the user grabbed. `.dragPreview` clips it to the same
            // rounded rectangle the row draws.
            .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 16))
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    archiveCandidate = row
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
            }
        }
    }

    private var archiveConfirmationBinding: Binding<Bool> {
        Binding(get: { archiveCandidate != nil }, set: { if !$0 { archiveCandidate = nil } })
    }

    /// A plain `NavigationLink` always appends its own trailing disclosure
    /// chevron in a `List` regardless of the label's own content — routing
    /// navigation through an invisible link and drawing the chevron inline
    /// ourselves is the only way to place it next to the text instead.
    private var archivedRow: some View {
        ZStack {
            NavigationLink("", destination: ArchiveAccountsView(session: session)).opacity(0)
            HStack(spacing: 4) {
                Text("Archived (\(archived.count))")
                    .foregroundStyle(Color.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                Spacer()
            }
        }
        .listRowInsets(EdgeInsets(top: 20, leading: 20, bottom: 8, trailing: 20))
    }

    /// A subtotal only means anything converted into one common currency —
    /// each account keeps its own native currency. Renders "—" (money rule
    /// 5), never a partial sum, the moment any account in the section has a
    /// missing rate: a subtotal that silently excluded one account's
    /// balance would look like a real total while quietly being wrong.
    private func subtotalText(for accounts: [LocalAccountRow]) -> String {
        guard let baseCurrency = accounts.first?.baseCurrencyInfo else { return "—" }
        let hasMissingRate = accounts.contains { $0.balanceBaseE4 == nil }
        let total: Int64? = hasMissingRate ? nil : accounts.reduce(Int64(0)) { $0 + ($1.balanceBaseE4 ?? 0) }
        return MoneyFormatter.format(total, currency: baseCurrency)
    }

    func load() async {
        actionErrorMessage = nil
        guard let ownerId = session.profile?.id, let baseCurrency = session.profile?.baseCurrency else {
            isLoading = false
            return
        }
        let dbQueue = session.dbQueue
        do {
            let rows = try await dbQueue.read { database in
                try LocalAccountRow.fetchAll(database, ownerId: ownerId.uuidString, baseCurrency: baseCurrency)
            }
            everyday = rows.filter { $0.kind == .regular && $0.archivedAt == nil }
            investments = rows.filter { $0.kind == .investment && $0.archivedAt == nil }
            archived = rows.filter { $0.archivedAt != nil }
        } catch {
            actionErrorMessage = UserFacingError.describe(error)
        }
        isLoading = false
    }

    /// B: goes through `session.outbox`, never `AccountRepository` directly —
    /// the local write-through lands (and this screen's list re-renders)
    /// before the network attempt even starts, and it works offline. A
    /// version conflict, if one happens, surfaces later via Needs Review.
    private func setArchived(_ row: LocalAccountRow, archived: Bool) async {
        actionErrorMessage = nil
        let payload = ArchiveAccountPayload(id: row.id, expectedVersion: row.version, archived: archived)
        await session.outbox.submitArchiveAccount(payload)
        session.refresh.bump()
    }
}
