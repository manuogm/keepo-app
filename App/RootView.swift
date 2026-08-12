import KeepoCore
import SwiftUI

/// Routes on SessionStore.phase: loading while signing in, OnboardingView
/// until a base currency + first account exist, main TabView after.
struct RootView: View {
    @State private var session = SessionStore()
    @State private var needsReviewCount = 0
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
                    .tabItem { Label("Dashboard", systemImage: "house") }

                    NavigationStack {
                        AccountsListView(session: session)
                    }
                    .tabItem { Label("Accounts", systemImage: "creditcard") }

                    NavigationStack {
                        TransactionsListView(session: session)
                    }
                    .tabItem { Label("Transactions", systemImage: "list.bullet") }
                    .badge(needsReviewCount > 0 ? needsReviewCount : 0)

                    NavigationStack {
                        ProfileView(session: session)
                    }
                    .tabItem { Label("My Profile", systemImage: "person.circle") }
                }
                .tint(Color.primary)
                .environment(\.isPrivacyMode, session.isPrivacyMode)
                .task(id: session.refresh.token) { await loadNeedsReviewCount() }
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
            if scenePhase != .active {
                privacyCurtain
            }
        }
        // Drain on foreground, not just at launch — a write made offline
        // should sync the moment connectivity is plausible again, without
        // waiting for the next cold start (Phase 11).
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await session.outbox.drainAll() }
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
