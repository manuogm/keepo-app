import KeepoCore
import SwiftUI

/// Every standing instruction the user has, as one list — reached from
/// Settings, not a top-level tab, matching the existing precedent
/// (Household/Sync Ritual aren't tabs either).
///
/// Nothing here ever queries or creates a materialized row: that is
/// `materialize_recurring`'s job alone, on its own daily cron schedule. Each
/// rule's `next_due_at` is shown directly, and a date in the past is shown
/// as such rather than tidied up — it is exactly what materialization
/// falling behind looks like.
///
/// **Rebuilt on the ledger's own row.** It used to be plain `List` rows of
/// text: no leading icon, no privacy mode, no base-currency line, and an
/// amount drawn with its minus sign while the identical transaction in the
/// Transactions tab drops it. The rows are `TransactionRow`'s anatomy now —
/// icon disc, title over a grey detail line, ledger-style amount with its
/// conversion underneath — because a recurring rule IS a transaction, seen
/// before it happens.
struct RecurringRulesView: View {
    let session: SessionStore

    @State private var rules: [LocalRecurringRuleRow] = []
    @State private var isLoading = true
    @State private var isAddingRule = false
    @State private var editingRule: PublicSchema.RecurringRulesSelect?
    @State private var actionError: ActionError?
    /// Rules whose switch has been flipped but whose write has not come back
    /// yet. The row reads its own state from here first, so the toggle moves
    /// under the finger instead of waiting for a round trip and a reload —
    /// and cannot be flipped twice while the first write is still going.
    @State private var pendingActive: [UUID: Bool] = [:]

    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()

            if isLoading {
                ProgressView()
            } else if rules.isEmpty {
                emptyState
            } else {
                ruleList
            }
        }
        .navigationTitle("Recurring")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAddingRule = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New recurring transaction")
            }
        }
        .sheet(isPresented: $isAddingRule) {
            RecurringRuleFormView(session: session) {
                session.refresh.bump()
            }
        }
        .sheet(item: $editingRule) { rule in
            RecurringRuleFormView(session: session, mode: .edit(rule)) {
                session.refresh.bump()
            }
        }
        .errorAlert($actionError)
        .task(id: session.refresh.token) { await load() }
    }

    // MARK: - Content

    /// **One card, no header.** The rules are already ordered by what matters
    /// — active first, then soonest due — and a heading over a list whose
    /// every row says for itself whether it is running would be labelling the
    /// same fact twice.
    ///
    /// **A `ScrollView` of rows on one card, not a `List`**, because this
    /// screen has no list affordance left to justify one. Swipe-to-delete is
    /// gone — a rule cannot be deleted at all (see `setActive`) — and with
    /// pause and resume both living on the switch there is no second action
    /// to swipe for. What remains is a group of rows on a surface, which is
    /// what `AutomationsView` and `ProfileView` already draw by hand.
    ///
    /// It also keeps a row with two independent controls out of `List`'s way.
    /// A `Button` inside a `List` row can have UIKit treat the whole cell as
    /// that button, which is why `ArchiveAccountsView` has to put
    /// `.buttonStyle(.borderless)` on each of its two — at the cost of the
    /// press state `.pressableRow` exists to draw. Not a bug this screen ever
    /// hit, and worth not being exposed to.
    private var ruleList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(rules) { rule in
                    RecurringRuleRow(
                        rule: rule,
                        isActive: pendingActive[rule.id] ?? rule.active,
                        isBusy: pendingActive[rule.id] != nil,
                        onToggle: { isOn in Task { await setActive(rule, to: isOn) } },
                        onOpen: { Task { await open(rule) } }
                    )
                    .padding(.horizontal, AppTheme.Spacing.l)

                    if rule.id != rules.last?.id {
                        Divider()
                            .padding(.leading, AppTheme.Size.dividerInset(icon: AppTheme.Size.icon))
                    }
                }
            }
            .background(AppTheme.Palette.bgSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.surface))
            .padding(AppTheme.Spacing.l)
        }
        .scrollBounceBehavior(.basedOnSize)
        .refreshable { await load() }
    }

    /// The illustrated shape `ScopeEmptyStateView` uses, rather than the one
    /// grey sentence this screen used to show. An empty list that offers no
    /// way to fill it is a dead end on a screen the user navigated three
    /// levels down to reach.
    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.m) {
            KeepoIcon(name: "icon-recurrent", size: AppTheme.Size.icon)
                .foregroundStyle(AppTheme.Palette.brandPrimary)
                .frame(width: AppTheme.Size.illustration, height: AppTheme.Size.illustration)
                .background(AppTheme.Palette.brandPrimary.opacity(AppTheme.Opacity.fill), in: Circle())

            VStack(spacing: AppTheme.Spacing.xs) {
                Text("No recurring transactions yet")
                    .font(AppTheme.Typography.rowTitle)
                Text("Set up rent, a subscription or a monthly transfer once, and Keepo files it every time.")
                    .font(AppTheme.Typography.label)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Button("Add Recurring") { isAddingRule = true }
                .font(AppTheme.Typography.labelEmphasis)
                .foregroundStyle(AppTheme.Palette.textOnAccent)
                .padding(.horizontal, AppTheme.Spacing.l)
                .padding(.vertical, AppTheme.Spacing.m)
                .background(AppTheme.Palette.brandPrimary, in: Capsule())
                .buttonStyle(.plain)
                .padding(.top, AppTheme.Spacing.xxs)
        }
        .padding(.horizontal, AppTheme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func load() async {
        guard let baseCurrency = session.profile?.baseCurrency else {
            isLoading = false
            return
        }
        do {
            rules = try await session.dbQueue.read { database in
                try LocalRecurringRuleRow.fetchAll(database, baseCurrency: baseCurrency)
            }
        } catch {
            actionError = ActionError("Couldn't Load Recurring Transactions", error)
        }
        isLoading = false
    }

    /// **The switch pauses; it never deletes.** A rule has already
    /// materialized real, historical transactions that must keep their
    /// `recurring_rule_id` pointing at something, so `recurring_rules` has no
    /// `deleted_at` at all — `active = false` simply stops the next one.
    ///
    /// That is also why the swipe-to-delete this list used to carry is gone.
    /// It rendered the system's red "Delete", which was a plain lie about
    /// what it did, and there was no gesture anywhere that could undo it: a
    /// paused rule could only be resumed by opening its form and finding a
    /// toggle at the bottom. One switch, on the row, does both directions.
    private func open(_ row: LocalRecurringRuleRow) async {
        do {
            editingRule = try await session.dbQueue.read { database in
                try LocalTableQueries.recurringRule(database, id: row.id.uuidString)
            }
        } catch {
            actionError = ActionError("Couldn't Open This Recurring Transaction", error)
        }
    }

    private func setActive(_ row: LocalRecurringRuleRow, to isActive: Bool) async {
        guard pendingActive[row.id] == nil else { return }
        pendingActive[row.id] = isActive
        do {
            try await RecurringRuleRepository.setActive(client: session.client, id: row.id, active: isActive)
            // Mirrored locally before the bump, because the bump reloads off
            // the mirror. Without this the switch springs back under the
            // finger while the server holds the new value — see
            // `RecurringRuleLocalWrite`.
            try await session.dbQueue.write { database in
                try RecurringRuleLocalWrite.setActive(id: row.id, active: isActive, in: database)
            }
            session.refresh.bump()
        } catch {
            actionError = ActionError(isActive ? "Couldn't Resume This Rule" : "Couldn't Pause This Rule", error)
        }
        // Cleared last, and in both outcomes: on success the reload that
        // `refresh.bump()` triggers has already rewritten `rules`, so the row
        // falls back to a server value that agrees; on failure it falls back
        // to the value it had, which is the switch springing back.
        pendingActive[row.id] = nil
    }
}

extension PublicSchema.RecurringRulesSelect: Identifiable {}
