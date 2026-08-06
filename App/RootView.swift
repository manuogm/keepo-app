import KeepoCore
import SwiftUI

/// Routes on SessionStore.phase: loading while signing in, OnboardingView
/// until a base currency + first account exist, AccountsListView after.
struct RootView: View {
    @State private var session = SessionStore()
    @State private var needsReviewCount = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch session.phase {
            case .loading:
                loadingView
            case .needsOnboarding:
                OnboardingView(session: session) {
                    Task { try? await session.refreshProfile() }
                }
            case .ready:
                TabView {
                    NavigationStack {
                        HomeView(session: session)
                    }
                    .tabItem { Label("Home", systemImage: "house") }

                    NavigationStack {
                        AccountsListView(session: session)
                    }
                    .tabItem { Label("Accounts", systemImage: "creditcard") }

                    NavigationStack {
                        TransactionsListView(session: session)
                    }
                    .tabItem { Label("Transactions", systemImage: "list.bullet") }

                    NavigationStack {
                        CategoriesView(session: session)
                    }
                    .tabItem { Label("Categories", systemImage: "tag") }

                    NavigationStack {
                        NeedsReviewView(session: session)
                    }
                    .tabItem { Label("Needs Review", systemImage: "tray.full") }
                    .badge(needsReviewCount)

                    NavigationStack {
                        SettingsView(session: session)
                    }
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                }
                .tint(Color("BrandPrimary"))
                .task(id: session.refresh.token) { await loadNeedsReviewCount() }
                .overlay(alignment: .bottom) {
                    if session.outbox.hasStalePending(threshold: staleOutboxThreshold) {
                        stalePendingBanner
                    }
                }
            case .failed(let message):
                errorView(message)
            }
        }
        .task { await session.start() }
        // Home (Phase 8) is the first screen whose whole purpose is a large
        // balance — the OS captures the app-switcher snapshot the instant
        // the scene stops being .active, so the curtain has to cover both
        // .inactive (switcher gesture starting) and .background, not just
        // the latter.
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

    /// Pending past 5 minutes reads as "probably actually offline," not
    /// "a normal in-flight request" — short enough to be useful, long
    /// enough that a momentary network blip never flashes it.
    private var staleOutboxThreshold: TimeInterval { 5 * 60 }

    private var stalePendingBanner: some View {
        HStack {
            Image(systemName: "icloud.slash")
            Text("\(session.outbox.pendingCount) change(s) waiting to sync")
                .font(.footnote)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color("BrandSecondary").opacity(0.15), in: Capsule())
        .foregroundStyle(Color("BrandSecondary"))
        .padding(.bottom, 8)
    }

    private func loadNeedsReviewCount() async {
        needsReviewCount = (try? await NeedsReviewRepository.fetchAll(client: session.client))?.count ?? 0
    }

    private var loadingView: some View {
        ZStack {
            Color("BGCanvas").ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text("Keepo")
                    .font(.title2).fontWeight(.bold)
                    .foregroundStyle(Color("TextPrimary"))
            }
        }
    }

    private var privacyCurtain: some View {
        ZStack {
            Color("BGCanvas").ignoresSafeArea()
            Text("Keepo")
                .font(.title2).fontWeight(.bold)
                .foregroundStyle(Color("TextPrimary"))
        }
    }

    private func errorView(_ message: String) -> some View {
        ZStack {
            Color("BGCanvas").ignoresSafeArea()
            VStack(spacing: 12) {
                Text("Couldn't connect")
                    .font(.title2).fontWeight(.bold)
                    .foregroundStyle(Color("TextPrimary"))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Color("TextSecondary"))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
    }
}

#Preview {
    RootView()
}
