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

    @Environment(AppNavigation.self) private var navigation: AppNavigation?
    @Environment(ScopeContext.self) private var scopeContext: ScopeContext?
    /// Optional for the same reason as `navigation`: a preview never
    /// installs one, and a coach mark is the last thing a preview needs.
    @Environment(FTUXCoordinator.self) private var ftux: FTUXCoordinator?

    /// Dragging rearranges — and converts between Everyday and Investments —
    /// only in Total. `reorder_accounts` writes each account's `sort_order`
    /// from its index in the array it is handed, so handing it a *filtered*
    /// subset would renumber those rows 1…n and leave every account the
    /// current scope hides sitting on the positions it just took. The
    /// gesture isn't disabled because a subset is hard to drag; it's
    /// disabled because a subset cannot express the thing being written.
    var isReorderable: Bool { session.scope == .total }

    /// Drag first, then Add — the order is `FTUXLessons.all`'s, not this
    /// array's, so it holds however these arrive.
    private var lessons: [FTUXLesson] {
        firstAccountId == nil ? [FTUXLessons.add] : [FTUXLessons.accounts, FTUXLessons.add]
    }

    /// Whether this row is the one the drag coach mark is pointing at right
    /// now — which is the only row, and the only moment, that needs a
    /// gesture recogniser of its own.
    private func isSpotlit(_ row: LocalAccountRow) -> Bool {
        row.id == firstAccountId && ftux?.isVisible(FTUXLessons.accounts) == true
    }

    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()

            VStack(spacing: 0) {
                ScopeBannerView(
                    title: "Accounts", session: session, onOpenProfile: { navigation?.openProfileRoot() }
                )
                .padding(.bottom, AppTheme.Spacing.xs)
                // The deck's cards tilt past their own bounds mid-swipe, and
                // nothing clips them — so the banner has to win against the
                // content underneath it.
                .zIndex(1)

                content
                    .fadingEdges()
            }

            if let actionErrorMessage {
                VStack {
                    Spacer()
                    Text(actionErrorMessage)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Palette.statusNegative)
                        .padding()
                }
            }
        }
        .dropsBottomSafeArea()
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: navigation?.pendingAdd) { _, _ in
            if navigation?.consumeAdd(.accounts) == true { isAddingAccount = true }
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
        .task(id: AccountsLoadKey(token: session.refresh.token, scope: session.scope)) { await load() }
        // Asked for from here because this screen is the only thing that
        // knows there is a row to point at — the drag lesson is a gesture
        // performed on an account, and an empty list cannot teach it. Add
        // is offered either way: the button is there whatever the list
        // holds, and an empty Accounts screen is exactly when somebody
        // needs to know how to fill it.
        .onAppear { Task { await ftux?.offer(lessons) } }
        .task(id: firstAccountId) { await ftux?.offer(lessons) }
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

    /// The scope's own blank state outranks the list — an Accounts screen
    /// under a Household banner with nothing shared should say so, not draw
    /// two empty group headers.
    @ViewBuilder
    private var content: some View {
        if let emptiness = scopeContext?.emptiness(for: session.scope) {
            ScopeEmptyStateView(emptiness: emptiness, session: session)
        } else if isLoading {
            Spacer()
            ProgressView()
            Spacer()
        } else {
            accountList
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
                    .moveDisabled(!isReorderable)
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
        .contentMargins(.bottom, KeepoTabBarMetrics.clearance, for: .scrollContent)
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
                    .padding(.horizontal, AppTheme.Spacing.m)
                    .padding(.vertical, AppTheme.Spacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        AppTheme.Palette.bgSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card)
                    )
            }
            .buttonStyle(.pressableRow)
            // The first account is what the coach mark cuts its hole
            // around: the lesson is about dragging *a row*, and the top one
            // is the one certain to be on screen.
            .ftuxAnchor(row.id == firstAccountId ? FTUXLessons.accounts : nil)
            // **Learning by doing ends the lesson.** The hole in the scrim
            // passes touches through, so this row is draggable while the
            // coach mark is up — and once the finger moves, the card
            // explaining the gesture is in the way of watching it. Attached
            // to the row rather than to the overlay because the overlay
            // deliberately cannot see a touch that went through its hole.
            //
            // **Zero distance, so this is really "a finger landed on the
            // row".** At 10pt it never fired: the list's own pan claims a
            // vertical drag inside a `List` before a competing gesture
            // reaches its threshold, which is precisely the drag being
            // taught. Touch-down is the one moment nothing else can take
            // first, and it is the right moment anyway — a tap, a long
            // press and a lift all mean the same thing here, which is that
            // the reading is over.
            //
            // `including: .none` while the mark is down, so nothing extra
            // is competing with the list's own drag in normal use.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in ftux?.dismiss(FTUXLessons.accounts) },
                including: isSpotlit(row) ? .all : .none
            )
            .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
            // Without this the lift preview snapshots the whole row rect —
            // a full-bleed, square-cornered slab that looks nothing like the
            // card the user grabbed. `.dragPreview` clips it to the same
            // rounded rectangle the row draws.
            .contentShape(.dragPreview, RoundedRectangle(cornerRadius: AppTheme.Radius.card))
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
            HStack(spacing: AppTheme.Spacing.xs) {
                Text("Archived (\(archived.count))")
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                Image(systemName: "chevron.right")
                    .font(AppTheme.Typography.micro)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
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
            let visible = rows.filter(isInScope)
            everyday = visible.filter { $0.kind == .regular && $0.archivedAt == nil }
            investments = visible.filter { $0.kind == .investment && $0.archivedAt == nil }
            archived = visible.filter { $0.archivedAt != nil }
        } catch {
            actionErrorMessage = UserFacingError.describe(error)
        }
        isLoading = false
    }

    /// The same rule `LocalMoneyQueries.scopeFilterSQL` applies in SQL,
    /// expressed against the row's own `isShared` — which is that exact
    /// `household_accounts` lookup, already done. Duplicating the predicate
    /// here rather than adding a scope term to `LocalAccountRow.fetchAll`
    /// keeps one query serving both this screen and the Transactions
    /// screen's own account filter menu, which wants every account.
    private func isInScope(_ row: LocalAccountRow) -> Bool {
        switch session.scope {
        case .total: return true
        case .me: return !row.isShared
        case .household: return row.isShared
        }
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

/// `.task(id:)` needs an `Equatable` id — the scope decides which accounts
/// this screen shows, so changing it has to reload exactly like a write does.
private struct AccountsLoadKey: Equatable {
    let token: Int
    let scope: PublicSchema.AccountScope
}
