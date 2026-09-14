import KeepoCore
import SwiftUI

/// The Needs Review inbox, as a drawer that drops out from underneath the
/// scope banner on the Transactions screen.
///
/// It used to be a bell in Home's toolbar opening a floating panel, and
/// that was wrong twice over: the items are transactions, so Home was the
/// wrong screen for them, and a circular icon button with a red dot said
/// "a number of things" without ever saying what. This says what — "3 items
/// need review" — in the place those items will be edited.
///
/// **Why it is drawn the way it is.** The drawer is exactly as wide as the
/// banner and is pulled *up* behind it by its own corner radius, so its top
/// edge is hidden and only its rounded bottom shows: it reads as something
/// that came out from under the banner rather than as a second card parked
/// below one. It owns no top corners for that reason. Collapsed it is one
/// row; **expanded it takes the whole screen** below the banner, because an
/// inbox you are working through is the screen, not a strip above one. It
/// renders nothing at all when the inbox is empty, so a healthy account
/// never pays for it in vertical space — and because it hides behind the
/// banner, nothing has to move when it appears.
///
/// Clearing the last item does not simply make it vanish: the drawer says
/// so, holds the moment, and then closes itself back onto the ledger. An
/// inbox that emptied silently gave no acknowledgement that the work was
/// finished, only a screen that had stopped being there.
///
/// One renderer switching on `item.kind` — `needs_review`'s stable column
/// contract (kind, item_id, account_id, occurred_at, title, subtitle,
/// amount, currency) means a later phase's new branch needs no change here
/// at all, only a new `case` in the icon/action switches below.
struct NeedsReviewPanel: View {
    let session: SessionStore
    /// Owned by the screen, not here: expanding hides the ledger, and the
    /// drawer cannot hide a sibling it does not own.
    @Binding var isExpanded: Bool

    @State var items: [PublicSchema.NeedsReviewSelect] = []
    @State var currencyMinorUnits: [String: Int] = [:]
    @State var actionErrorMessage: String?
    @State var editingTransaction: PublicSchema.TransactionsWithDetailsSelect?
    @State var mappingCard: PublicSchema.NeedsReviewSelect?
    @State var showCardMapping = false
    @State var conflictId: UUID?
    /// Held on screen for a beat after the last item goes, then closes the
    /// drawer. Also what keeps the drawer rendered at all past that point —
    /// see `isVisible`.
    @State private var showSuccess = false

    /// The app's one accent. An inbox is a reminder, so it must catch the
    /// eye *without* reading as an error — which is why this is mango and
    /// not `statusNegative`, the only other colour that would pull a glance.
    private var accent: Color { AppTheme.Palette.brandPrimary }

    private enum Metrics {
        /// The drawer's bottom radius, and equally the distance it hides
        /// behind the banner — the two are the same number because the
        /// hidden part *is* the top corners nobody should see. One token, so
        /// the drawer's corner can never drift away from the sheets and
        /// widgets it sits among.
        static let radius = AppTheme.Radius.surface
    }

    var body: some View {
        // A `VStack`, not a `Group` resolving to `EmptyView`: modifiers on
        // an empty branch are not reliably honoured, and the `.task` below
        // is what fills `items` in the first place — so the panel that
        // renders nothing until it has items must not be the thing deciding
        // whether the load runs.
        VStack(spacing: 0) {
            if isVisible {
                panel
            }
        }
        .frame(maxHeight: isExpanded ? .infinity : nil)
        .task(id: session.refresh.token) { await load() }
        .onChange(of: items.isEmpty) { _, isEmpty in
            guard isEmpty, isExpanded else { return }
            showSuccess = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation(AppTheme.Motion.standard) {
                    showSuccess = false
                    isExpanded = false
                }
            }
        }
        .sheet(item: $editingTransaction) { transaction in
            TransactionFormView(session: session, mode: .edit(transaction, sibling: nil)) {
                session.refresh.bump()
            }
        }
        .sheet(isPresented: $showCardMapping) {
            if let mappingCard {
                MapCardSheet(session: session, item: mappingCard) {
                    session.refresh.bump()
                }
            }
        }
        .sheet(item: $conflictId) { id in
            ConflictDetailSheet(session: session, conflictId: id) {
                session.refresh.bump()
            }
        }
    }

    /// Rendered while there is anything to say — items to review, or the
    /// fact that there are no longer any.
    private var isVisible: Bool { !items.isEmpty || showSuccess }

    private var panel: some View {
        VStack(spacing: 0) {
            // The strip that lives behind the banner. Flat, no corners, no
            // content — it exists so the drawer has something to be pulled
            // out of.
            Color.clear.frame(height: Metrics.radius)

            if showSuccess {
                successState
            } else {
                header
                if isExpanded {
                    Divider().padding(.leading, AppTheme.Size.dividerInset(icon: AppTheme.Size.icon))
                    itemList
                }
            }
        }
        .background(
            AppTheme.Palette.bgSurface,
            in: UnevenRoundedRectangle(
                bottomLeadingRadius: Metrics.radius, bottomTrailingRadius: Metrics.radius, style: .continuous
            )
        )
        .elevation(.resting)
        .padding(.top, -Metrics.radius)
        .frame(maxHeight: isExpanded ? .infinity : nil, alignment: .top)
        .animation(AppTheme.Motion.standard, value: isExpanded)
        .animation(AppTheme.Motion.standard, value: items.count)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Takes the rest of the screen, because expanding is the user saying
    /// they are here to work through the list.
    private var itemList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(items, id: \.itemId) { item in
                    row(item)
                    if item.itemId != items.last?.itemId {
                        Divider().padding(.leading, AppTheme.Size.dividerInset(icon: AppTheme.Size.icon))
                    }
                }
            }

            if let actionErrorMessage {
                Text(actionErrorMessage)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.statusNegative)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppTheme.Spacing.l)
                    .padding(.top, AppTheme.Spacing.m)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .contentMargins(.bottom, KeepoTabBarMetrics.clearance, for: .scrollContent)
        .frame(maxHeight: .infinity)
        // The rows only, not the drawer: expanded, this reaches the bottom
        // of the display like the ledger it replaces, so it needs the same
        // fade under the tab bar — but masking the whole drawer would
        // dissolve its own surface along with them. There is nothing to
        // fade at the top; the drawer's header is above this.
        .fadingEdges(top: 0)
        .transition(.opacity)
    }

    private var successState: some View {
        VStack(spacing: AppTheme.Spacing.m) {
            Image(systemName: "checkmark")
                .font(AppTheme.Typography.sectionTitle)
                .foregroundStyle(AppTheme.Palette.textOnAccent)
                .frame(width: AppTheme.Size.avatar, height: AppTheme.Size.avatar)
                .background(accent, in: Circle())
            VStack(spacing: AppTheme.Spacing.xs) {
                Text("All caught up")
                    .font(AppTheme.Typography.rowTitle)
                Text("Nothing else needs your review.")
                    .font(AppTheme.Typography.label)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, AppTheme.Spacing.xxl)
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }

    private var header: some View {
        Button {
            withAnimation(AppTheme.Motion.standard) { isExpanded.toggle() }
        } label: {
            HStack(spacing: AppTheme.Spacing.m) {
                KeepoIcon(name: "icon-inbox", size: AppTheme.Size.icon)
                    .foregroundStyle(accent)
                    .background(accent.opacity(AppTheme.Opacity.fill), in: Circle())

                Text(headline)
                    .font(AppTheme.Typography.labelEmphasis)
                    .foregroundStyle(AppTheme.Palette.textPrimary)

                Spacer()

                Image(systemName: "chevron.down")
                    .font(AppTheme.Typography.microEmphasis)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .padding(.horizontal, AppTheme.Spacing.l)
            .padding(.vertical, AppTheme.Spacing.m)
        }
        .buttonStyle(.pressableRow)
        .accessibilityHint(isExpanded ? "Collapses the list" : "Expands the list")
    }

    private var headline: String {
        items.count == 1 ? "1 item needs review" : "\(items.count) items need review"
    }

    /// The row's whole surface opens the item's own review flow; the trailing
    /// pill is the one-tap version of that flow's outcome where one exists.
    /// The destructive options (dismiss an unmappable card, reject an import
    /// candidate) are a context menu rather than a swipe — this panel is
    /// inside a scrolling screen, not a `List`, so there is no swipe gesture
    /// to attach them to.
    private func row(_ item: PublicSchema.NeedsReviewSelect) -> some View {
        HStack(spacing: AppTheme.Spacing.s) {
            Button {
                open(item)
            } label: {
                NeedsReviewRow(item: item, minorUnit: minorUnit(for: item.currency))
                    .padding(.vertical, AppTheme.Spacing.s)
                    .padding(.leading, AppTheme.Spacing.l)
            }
            .buttonStyle(.pressableRow)

            if let quick = quickAction(item) {
                Button(quick.title) { perform(quick.kind, on: item) }
                    .font(AppTheme.Typography.microEmphasis)
                    .foregroundStyle(accent)
                    .padding(.horizontal, AppTheme.Spacing.s)
                    .padding(.vertical, AppTheme.Spacing.xs)
                    .background(accent.opacity(AppTheme.Opacity.fill), in: Capsule())
                    .buttonStyle(.plain)
                    .padding(.trailing, AppTheme.Spacing.l)
            }
        }
        .contextMenu {
            if let destructive = destructiveAction(item) {
                Button(destructive.title, role: .destructive) { perform(destructive.kind, on: item) }
            }
        }
    }

    func minorUnit(for currencyCode: String?) -> Int {
        guard let currencyCode else { return 2 }
        return currencyMinorUnits[currencyCode] ?? 2
    }
}

struct NeedsReviewRow: View {
    let item: PublicSchema.NeedsReviewSelect
    let minorUnit: Int

    var body: some View {
        HStack(spacing: AppTheme.Spacing.m) {
            Image(systemName: iconName)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .frame(width: AppTheme.Size.icon)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(item.title ?? "—")
                    .font(AppTheme.Typography.label)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(AppTheme.Typography.micro)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                }
            }
            Spacer(minLength: AppTheme.Spacing.s)
            if let amount = item.amountE4, let currencyCode = item.currency {
                Text(MoneyFormatter.format(amount, currency: CurrencyInfo(code: currencyCode, minorUnit: minorUnit)))
                    .font(AppTheme.Typography.label)
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.Palette.textPrimary)
            }
        }
        .lineLimit(1)
    }

    private var iconName: String {
        switch item.kind {
        case "sync_conflict": return "exclamationmark.arrow.triangle.2.circlepath"
        case "pending_capture": return "wallet.pass"
        case "ambiguous_card": return "creditcard.trianglebadge.exclamationmark"
        default: return "questionmark.circle"
        }
    }
}
