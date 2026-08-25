import KeepoCore
import SwiftUI

/// The signed-in app shell — four tabs plus the offline/pending-sync status
/// overlay. Extracted from `RootView` so the root router stays a thin
/// traffic controller; this owns everything specific to the `.ready`
/// session phase.
struct MainTabView: View {
    let session: SessionStore
    let network: NetworkMonitor

    @State private var needsReviewCount = 0
    /// Owned here because this is the only view that can act on it — the tab
    /// bar is the thing being driven. Handed down through the environment so
    /// a widget four layers into Home can ask for a tab switch without every
    /// signature between here and it carrying a navigation parameter.
    @State private var navigation = AppNavigation()

    var body: some View {
        TabView(selection: $navigation.tab) {
            NavigationStack {
                HomeView(session: session)
            }
            .tabItem { Label("Home", systemImage: "globe") }
            .badge(needsReviewCount > 0 ? needsReviewCount : 0)
            .tag(AppNavigation.Tab.home)

            NavigationStack {
                AccountsListView(session: session)
            }
            .tabItem { Label("Accounts", systemImage: "creditcard") }
            .tag(AppNavigation.Tab.accounts)

            NavigationStack {
                TransactionsListView(session: session)
            }
            .tabItem { Label("Transactions", systemImage: "list.bullet") }
            .tag(AppNavigation.Tab.transactions)

            NavigationStack {
                ProfileView(session: session)
            }
            .tabItem { Label("My Profile", systemImage: "person.circle") }
            .tag(AppNavigation.Tab.profile)
        }
        .tint(Color.primary)
        .environment(navigation)
        .environment(\.isPrivacyMode, session.isPrivacyMode)
        // Presented from here rather than `RootView` — see
        // `CaptureDeepLinkModifier`'s own header for the two device-testing
        // bugs that presenting it from outside this `TabView` caused.
        .captureDeepLink(session: session)
        .task(id: session.refresh.token) { await loadNeedsReviewCount() }
        // `.overlay`, not `.safeAreaInset` — iOS 26's floating pill tab
        // bar renders above the safe area it reports, so a view
        // placed relative to that reported inset still lands behind
        // the pill's own visual bounds. Floating our own banner a
        // fixed distance off the true screen bottom sidesteps that
        // mismatch entirely.
        .overlay(alignment: .bottom) {
            if network.isOffline {
                OfflineStatusBar(lastSyncedAt: session.syncEngine?.lastSyncedAt)
                    .padding(.horizontal)
                    .padding(.bottom, 60)
            } else if session.outbox.hasStalePending(threshold: 120)
                || session.syncEngine?.lastErrorMessage != nil {
                PendingSyncStatusBar(
                    pendingCount: session.outbox.pendingCount,
                    errorMessage: session.outbox.lastError ?? session.syncEngine?.lastErrorMessage,
                    retry: { await session.syncNow() }
                )
                .padding(.horizontal)
                .padding(.bottom, 60)
            }
        }
    }

    /// Local mirror, not a network read (X-01) — this used to call
    /// `NeedsReviewRepository.fetchAll` against the server view, which
    /// disagreed with `HomeView`'s bell-dot count (computed from
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
