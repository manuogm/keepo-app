import KeepoCore
import SwiftUI

/// Routes on SessionStore.phase: loading while signing in, OnboardingView
/// until a base currency + first account exist, AccountsListView after.
struct RootView: View {
    @State private var session = SessionStore()
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
                        SettingsView(session: session)
                    }
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                }
                .tint(Color("BrandPrimary"))
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
