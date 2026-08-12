import KeepoCore
import SwiftUI

struct ProfileView: View {
    let session: SessionStore

    @State private var isSigningOut = false
    @State private var signOutError: String?

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            List {
                Section {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Color.primary.opacity(0.15))
                                .frame(width: 64, height: 64)
                            Text(avatarInitial)
                                .font(.title2.bold())
                                .foregroundStyle(Color.primary)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.userEmail ?? "—")
                                .font(.headline)
                                .foregroundStyle(Color.primary)
                            if let currency = session.profile?.baseCurrency {
                                Text("Base currency: \(currency)")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    NavigationLink("My Household") {
                        HouseholdView(session: session)
                    }
                } footer: {
                    Text("Invite a partner, share accounts, or leave — your data is always yours.")
                }

                Section {
                    NavigationLink("Automations") {
                        AutomationsView(session: session)
                    }
                    NavigationLink("Preferences") {
                        PreferencesView(session: session)
                    }
                    NavigationLink("Data & Privacy") {
                        DataPrivacyView(session: session)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        Task { await signOut() }
                    } label: {
                        HStack {
                            Text("Sign Out")
                            Spacer()
                            if isSigningOut {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isSigningOut)
                    if let signOutError {
                        Text(signOutError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("My Profile")
    }

    private var avatarInitial: String {
        String((session.userEmail ?? "?").prefix(1)).uppercased()
    }

    private func signOut() async {
        isSigningOut = true
        signOutError = nil
        do {
            try await session.signOut()
        } catch {
            signOutError = UserFacingError.describe(error)
            isSigningOut = false
        }
    }
}
