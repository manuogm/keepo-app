import KeepoCore
import SwiftUI

/// The signed-in app shell — three icon-only tabs, the Add button beside
/// them, the Profile sheet, and the offline/pending-sync status overlay.
/// Extracted from `RootView` so the root router stays a thin traffic
/// controller; this owns everything specific to the `.ready` session phase.
struct MainTabView: View {
    let session: SessionStore
    let network: NetworkMonitor

    @State private var needsReviewCount = 0
    /// Owned here because this is the only view that can act on it — the tab
    /// bar is the thing being driven. Handed down through the environment so
    /// a widget four layers into Home can ask for a tab switch without every
    /// signature between here and it carrying a navigation parameter.
    @State private var navigation = AppNavigation()
    /// Loaded here, once, for the same reason: all three screens render the
    /// identical "this scope is empty" answer, and the read behind it is
    /// the same read whichever screen asks.
    @State private var scopeContext = ScopeContext()
    /// Measured here and handed down, because this is the last view that
    /// still sees it — see `EnvironmentValues.topSafeAreaInset`.
    @State private var topSafeAreaInset: CGFloat = 0

    var body: some View {
        @Bindable var navigation = navigation
        return TabView(selection: $navigation.tab) {
            NavigationStack {
                HomeView(session: session)
            }
            .toolbar(.hidden, for: .tabBar)
            .tag(AppNavigation.Tab.home)

            NavigationStack {
                AccountsListView(session: session)
            }
            .toolbar(.hidden, for: .tabBar)
            .tag(AppNavigation.Tab.accounts)

            NavigationStack {
                TransactionsListView(session: session)
            }
            .toolbar(.hidden, for: .tabBar)
            .tag(AppNavigation.Tab.transactions)
        }
        .tint(Color.primary)
        .environment(navigation)
        .environment(scopeContext)
        .environment(\.isPrivacyMode, session.isPrivacyMode)
        .environment(\.topSafeAreaInset, topSafeAreaInset)
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topSafeAreaInset = $0 }
        // A safe-area inset, not an overlay: the system bar is hidden, so
        // this is the only thing telling a list where its content actually
        // ends. (The offline banner below stays an overlay — see its own
        // comment; it floats *over* content by design.)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            KeepoTabBar(
                tab: $navigation.tab, needsReviewCount: needsReviewCount, onAdd: { navigation.requestAdd() }
            )
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
        // Presented from here rather than `RootView` — see
        // `CaptureDeepLinkModifier`'s own header for the two device-testing
        // bugs that presenting it from outside this `TabView` caused.
        .captureDeepLink(session: session)
        .sheet(isPresented: $navigation.isProfilePresented) {
            NavigationStack(path: $navigation.profilePath) {
                ProfileView(session: session)
                    .navigationDestination(for: AppNavigation.ProfileDestination.self) { destination in
                        profileDestination(destination)
                    }
            }
        }
        .task(id: session.refresh.token) {
            await loadNeedsReviewCount()
            await scopeContext.reload(session: session)
        }
        // `.overlay`, not `.safeAreaInset` — the banner is a transient
        // floating notice that must not reflow the screen under it every
        // time connectivity blips. It clears the tab bar by sitting on the
        // inset that bar already claims.
        .overlay(alignment: .bottom) {
            if network.isOffline {
                OfflineStatusBar(lastSyncedAt: session.syncEngine?.lastSyncedAt)
                    .padding(.horizontal)
                    .padding(.bottom, 76)
            } else if session.outbox.hasStalePending(threshold: 120)
                || session.syncEngine?.lastErrorMessage != nil {
                PendingSyncStatusBar(
                    pendingCount: session.outbox.pendingCount,
                    errorMessage: session.outbox.lastError ?? session.syncEngine?.lastErrorMessage,
                    retry: { await session.syncNow() }
                )
                .padding(.horizontal)
                .padding(.bottom, 76)
            }
        }
    }

    /// The Profile sheet's pushable screens, in one place. `ProfileView`'s
    /// own rows are value links into this same table, so a row tap and a
    /// programmatic `openProfile` land on exactly the same view.
    @ViewBuilder
    private func profileDestination(_ destination: AppNavigation.ProfileDestination) -> some View {
        switch destination {
        case .household: HouseholdView(session: session)
        case .automations: AutomationsView(session: session)
        case .preferences: PreferencesView(session: session)
        case .dataPrivacy: DataPrivacyView(session: session)
        }
    }

    /// Local mirror, not a network read (X-01) — this used to call
    /// `NeedsReviewRepository.fetchAll` against the server view, which
    /// disagreed with the in-app count (computed from
    /// `LocalMoneyQueries.needsReview`) whenever a capture hadn't synced
    /// yet, and silently dropped to 0 offline (`try?` swallowing the
    /// network failure). Same query both badges now read.
    private func loadNeedsReviewCount() async {
        guard let ownerId = session.profile?.id else {
            needsReviewCount = 0
            return
        }
        let dbQueue = session.dbQueue
        needsReviewCount = (try? await dbQueue.read { database in
            try LocalMoneyQueries.needsReview(database, ownerId: ownerId.uuidString).count
        }) ?? 0
    }
}
