import KeepoCore
import SwiftUI
import UIKit

/// Routes on SessionStore.phase: loading while signing in, OnboardingView
/// until a base currency + first account exist, main TabView after.
struct RootView: View {
    @State private var session = SessionStore()
    @State private var network = NetworkMonitor()
    @State private var needsReviewCount = 0
    /// Backs the privacy curtain instead of `@Environment(\.scenePhase)` —
    /// SwiftUI's `scenePhase` is documented (and reproduces on real devices,
    /// never in the simulator) to flicker to `.inactive` for reasons that
    /// have nothing to do with backgrounding — app-launch settling, sheet/
    /// alert presentation transitions — and the curtain has no debounce or
    /// `allowsHitTesting(false)` guard (it can't: it must block real
    /// backgrounding instantly, before the app-switcher snapshot). Every
    /// false-positive flicker silently ate the next tap. `UIApplication`'s
    /// own `willResignActive`/`didBecomeActive` notifications are the
    /// authoritative signal for "about to stop being the active app" (the
    /// same instant the OS takes the switcher snapshot) without that quirk.
    @State private var isSceneActive = true
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppSettingsKeys.appearanceMode) private var appearanceMode = AppearanceMode.system

    var body: some View {
        Group {
            switch session.phase {
            case .loading:
                loadingView
            case .needsSignIn:
                OTPSignInView(session: session)
            case .needsOnboarding:
                OnboardingView(session: session) {
                    Task { try? await session.refreshProfile() }
                }
            case .ready:
                TabView {
                    NavigationStack {
                        HomeView(session: session)
                    }
                    .tabItem { Label("Home", systemImage: "globe") }
                    .badge(needsReviewCount > 0 ? needsReviewCount : 0)

                    NavigationStack {
                        AccountsListView(session: session)
                    }
                    .tabItem { Label("Accounts", systemImage: "creditcard") }

                    NavigationStack {
                        TransactionsListView(session: session)
                    }
                    .tabItem { Label("Transactions", systemImage: "list.bullet") }

                    NavigationStack {
                        ProfileView(session: session)
                    }
                    .tabItem { Label("My Profile", systemImage: "person.circle") }
                }
                .tint(Color.primary)
                .environment(\.isPrivacyMode, session.isPrivacyMode)
                .task(id: session.refresh.token) { await loadNeedsReviewCount() }
                .safeAreaInset(edge: .bottom) {
                    if network.isOffline {
                        OfflineStatusBar(lastSyncedAt: session.syncEngine?.lastSyncedAt)
                            .padding(.horizontal)
                            .padding(.bottom, 4)
                    }
                }
            case .failed(let message):
                errorView(message)
            }
        }
        .preferredColorScheme(appearanceMode.colorScheme)
        .task { await session.start() }
        .onOpenURL { url in
            Task { await session.handleMagicLink(url: url) }
        }
        // Dashboard (Phase 8) is the first screen whose whole purpose is a
        // large balance — the OS captures the app-switcher snapshot the
        // instant the scene stops being .active, so the curtain has to cover
        // both .inactive (switcher gesture starting) and .background.
        .overlay {
            if !isSceneActive {
                privacyCurtain
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            isSceneActive = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            isSceneActive = true
        }
        // Drain on foreground, not just at launch — a write made offline
        // should sync the moment connectivity is plausible again, without
        // waiting for the next cold start (Phase 11).
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    await session.outbox.drainAll()
                    await session.syncEngine?.pull()
                    session.refresh.bump()
                }
            }
        }
        // L5: connectivity regained is exactly the other "went offline,
        // came back" moment `Outbox.drainAll()` already needed on
        // foreground — the sync engine's pull needs the identical trigger.
        .onChange(of: network.isOffline) { wasOffline, isOffline in
            if wasOffline && !isOffline {
                Task {
                    await session.syncEngine?.pull()
                    session.refresh.bump()
                }
            }
        }
    }

    private func loadNeedsReviewCount() async {
        let items = (try? await NeedsReviewRepository.fetchAll(client: session.client)) ?? []
        needsReviewCount = items.filter { $0.kind != "reconciliation_gap" }.count
    }

    private var loadingView: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text("Keepo")
                    .font(.title2).fontWeight(.bold)
                    .foregroundStyle(Color.primary)
            }
        }
    }

    private var privacyCurtain: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            Text("Keepo")
                .font(.title2).fontWeight(.bold)
                .foregroundStyle(Color.primary)
        }
    }

    private func errorView(_ message: String) -> some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            VStack(spacing: 12) {
                Text("Couldn't connect")
                    .font(.title2).fontWeight(.bold)
                    .foregroundStyle(Color.primary)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
    }
}

#Preview {
    RootView()
}
