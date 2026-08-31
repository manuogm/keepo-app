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

    /// Mango, not coral: `keepo-brand-identity.md` §1 gives `BrandSecondary`
    /// to reminders and benchmarks and `BrandPrimary` to data and actions.
    /// An inbox is a reminder — it should catch the eye without reading as
    /// an error.
    private var accent: Color { Color(hex: "#FF9F1C") }

    private enum Metrics {
        /// The drawer's bottom radius, and equally the distance it hides
        /// behind the banner — the two are the same number because the
        /// hidden part *is* the top corners nobody should see.
        static let radius: CGFloat = 24
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
                withAnimation(.snappy(duration: 0.3)) {
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
                    Divider().padding(.leading, 56)
                    itemList
                }
            }
        }
        .background(
            Color(.secondarySystemGroupedBackground),
            in: UnevenRoundedRectangle(
                bottomLeadingRadius: Metrics.radius, bottomTrailingRadius: Metrics.radius, style: .continuous
            )
        )
        .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
        .padding(.top, -Metrics.radius)
        .frame(maxHeight: isExpanded ? .infinity : nil, alignment: .top)
        .animation(.snappy(duration: 0.28), value: isExpanded)
        .animation(.snappy(duration: 0.28), value: items.count)
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
                        Divider().padding(.leading, 56)
                    }
                }
            }

            if let actionErrorMessage {
                Text(actionErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: .infinity)
        .transition(.opacity)
    }

    private var successState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 64, height: 64)
                .background(accent, in: Circle())
            VStack(spacing: 4) {
                Text("All caught up")
                    .font(.headline)
                Text("Nothing else needs your review.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }

    private var header: some View {
        Button {
            withAnimation(.snappy(duration: 0.3)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 28, height: 28)
                    .background(accent.opacity(0.15), in: Circle())

                Text(headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)

                Spacer()

                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.secondary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
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
        HStack(spacing: 10) {
            Button {
                open(item)
            } label: {
                NeedsReviewRow(item: item, minorUnit: minorUnit(for: item.currency))
                    .padding(.vertical, 10)
                    .padding(.leading, 16)
            }
            .buttonStyle(.pressableRow)

            if let quick = quickAction(item) {
                Button(quick.title) { perform(quick.kind, on: item) }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(accent.opacity(0.14), in: Capsule())
                    .buttonStyle(.plain)
                    .padding(.trailing, 16)
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
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 14))
                .foregroundStyle(Color.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title ?? "—")
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }
            Spacer(minLength: 8)
            if let amount = item.amountE4, let currencyCode = item.currency {
                Text(MoneyFormatter.format(amount, currency: CurrencyInfo(code: currencyCode, minorUnit: minorUnit)))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(Color.primary)
            }
        }
        .lineLimit(1)
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
