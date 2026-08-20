import KeepoCore
import SwiftUI

/// Home — a widget dashboard the user arranges themselves, plus the screen
/// chrome that was always here: the top-left "more options" button that
/// picks the scope every financial screen computes for, and the bell that
/// opens the Needs Review inbox as a floating notifications panel. Scope
/// lives in SessionStore so it persists across tab switches and drives every
/// financial screen from the same source of truth — and, on this screen,
/// every widget at once.
///
/// The dashboard replaced Home's *body*, not Home: the toolbar, the overlay
/// cards, and the needs-review plumbing below are unchanged. What used to be
/// a single hard-coded net-worth card is now `DashboardCanvasView`, and the
/// widgets on it are `DashboardStore`'s business.
///
/// Reads straight off the local GRDB mirror (Phase L6) — no server round
/// trip, no payload cache, no pending-write overlay. `Outbox`'s optimistic
/// write-through means an offline (or just-submitted online) edit is
/// already in the same tables this screen queries, so there is nothing left
/// for an overlay to add: one number, one source.
struct HomeView: View {
    let session: SessionStore

    /// Owned here rather than in `SessionStore`: the arrangement is this
    /// screen's, it is device-local, and nothing outside Home reads it.
    @State private var store = DashboardStore()
    @State private var data = DashboardData()
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var needsReviewCount = 0
    // Kept, not just the count — so opening the bell popover can seed
    // `NeedsReviewView` with rows already in hand instead of it blanking to
    // a spinner and re-querying the same local table this screen just read
    // (the "notification button ... laggy" complaint: a fresh `NeedsReviewView`
    // starts `isLoading = true` every time it's constructed here).
    @State private var needsReviewItems: [PublicSchema.NeedsReviewSelect] = []
    @State private var needsReviewCurrencyMinorUnits: [String: Int] = [:]
    @State private var showNotifications = false
    @State private var showScopeMenu = false
    /// Lifted out of the canvas so the toolbar can offer "Done" — the canvas
    /// owns entering edit mode (via long press), the toolbar owns the most
    /// obvious way out of it.
    @State private var isEditing = false

    private var isOverlayPresented: Bool { showNotifications || showScopeMenu }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            DashboardCanvasView(
                session: session, store: store, data: data, isLoading: isLoading, isEditing: $isEditing
            )

            if let errorMessage {
                VStack {
                    Spacer()
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                }
            }

            // Both top-bar buttons present as a plain SwiftUI overlay here —
            // not a system `.popover` — because a popover's own outside-tap
            // dismissal happens above our content and gives us no reliable
            // hook to keep a background curtain in sync with it (tested:
            // both watching its delayed `isPresented` flip and trying to
            // race it with our own tap gesture failed). Owning the whole
            // presentation ourselves means one piece of state drives the
            // trigger, the curtain, and the outside-tap dismiss together.
            Color.black.opacity(isOverlayPresented ? 0.25 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(isOverlayPresented)
                .onTapGesture {
                    showScopeMenu = false
                    showNotifications = false
                }

            if showScopeMenu {
                scopeMenuCard
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 4)
                    .padding(.leading, 8)
                    .transition(.scale(scale: 0.85, anchor: .topLeading).combined(with: .opacity))
            }

            if showNotifications {
                notificationsCard
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 4)
                    .padding(.trailing, 8)
                    .transition(.scale(scale: 0.85, anchor: .topTrailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isOverlayPresented)
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showScopeMenu = true
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
            ToolbarItem(placement: .principal) {
                ScreenTitleBar(title: "Home", session: session)
            }
            ToolbarItem(placement: .primaryAction) {
                // Edit mode borrows this slot: while arranging, the bell is
                // the wrong thing to offer and "Done" is the only thing the
                // user wants. Tapping the surface around the widgets also
                // finishes, but that is not discoverable on its own.
                if isEditing {
                    Button("Done") {
                        withAnimation(.snappy(duration: 0.24)) { isEditing = false }
                    }
                    .font(.body.weight(.semibold))
                } else {
                    Button {
                        showNotifications = true
                    } label: {
                        Image(systemName: "bell")
                    }
                    .overlay(alignment: .topTrailing) {
                        if needsReviewCount > 0 {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                                .offset(x: 2, y: -2)
                        }
                    }
                }
            }
        }
        // Keyed on the mounted widget kinds as well as the refresh token and
        // the scope: adding or removing a widget has to reload, because the
        // loader deliberately computes nothing for a widget that isn't there.
        .task(id: HomeLoadKey(token: session.refresh.token, scope: session.scope, kinds: store.mountedKinds)) {
            await load()
        }
    }

    /// Rows keep their identity icon (globe/person/person.2) even when
    /// selected — the checkmark is appended at the trailing edge instead of
    /// replacing it, so which option is which stays visible at a glance.
    private var scopeMenuCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            scopeRow(.total, label: "Total Net Worth", icon: "globe")
            Divider()
            scopeRow(.me, label: "Personal", icon: "person.fill")
            Divider()
            scopeRow(.household, label: "Household", icon: "person.2.fill")
        }
        .padding(.vertical, 4)
        .frame(width: 220)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }

    private var notificationsCard: some View {
        NavigationStack {
            NeedsReviewView(
                session: session, seed: (items: needsReviewItems, currencyMinorUnits: needsReviewCurrencyMinorUnits)
            )
        }
        .frame(width: 340, height: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }

    private func scopeRow(_ scope: PublicSchema.AccountScope, label: String, icon: String) -> some View {
        Button {
            session.scope = scope
            showScopeMenu = false
        } label: {
            HStack {
                Image(systemName: icon)
                    .frame(width: 20)
                Text(label)
                Spacer()
                if session.scope == scope {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
    }

    /// One read for the whole dashboard, plus the bell's own rows. Widget
    /// figures come back as a single `DashboardData` value — see
    /// `DashboardDataLoader` for why this is one query rather than one per
    /// widget.
    private func load() async {
        errorMessage = nil
        guard let baseCurrency = session.profile?.baseCurrency, let ownerId = session.profile?.id else {
            isLoading = false
            return
        }
        do {
            data = try await DashboardDataLoader.load(
                dbQueue: session.dbQueue, scope: session.scope, baseCurrency: baseCurrency,
                kinds: store.mountedKinds
            )
            try await loadNeedsReview(ownerId: ownerId)
        } catch {
            // A cancelled load is not a failure — the task id changed and a
            // fresh load is already running. Same shape as `HouseholdView`'s
            // own `isOffline` check: the caller knows which errors are worth
            // a red line and which are not.
            errorMessage = UserFacingError.isCancellation(error) ? nil : UserFacingError.describe(error)
        }
        isLoading = false
    }

    private func loadNeedsReview(ownerId: UUID) async throws {
        let loaded = try await session.dbQueue.read { database in
            (
                try LocalTableQueries.currencies(database),
                try LocalMoneyQueries.needsReview(database, ownerId: ownerId.uuidString)
            )
        }
        let (currencies, reviewRows) = loaded
        needsReviewItems = try reviewRows.map { try LocalTransactionRow.needsReviewSelect(from: $0) }
        needsReviewCurrencyMinorUnits = Dictionary(
            uniqueKeysWithValues: currencies.map { ($0.code, Int($0.minorUnit)) }
        )
        needsReviewCount = needsReviewItems.count
    }
}

/// `.task(id:)` needs an `Equatable` id — bundles the refresh token, the
/// scope, and the mounted widget kinds so any of the three changing triggers
/// exactly one reload.
private struct HomeLoadKey: Equatable {
    let token: Int
    let scope: PublicSchema.AccountScope
    let kinds: Set<DashboardWidgetKind>
}
