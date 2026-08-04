import KeepoCore
import SwiftUI

/// Routes on SessionStore.phase: loading while signing in, OnboardingView
/// until a base currency + first account exist, AccountsListView after.
struct RootView: View {
    @State private var session = SessionStore()

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
                }
                .tint(Color("BrandPrimary"))
            case .failed(let message):
                errorView(message)
            }
        }
        .task { await session.start() }
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
