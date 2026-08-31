import KeepoCore
import SwiftUI

struct ProfileView: View {
    let session: SessionStore

    @State private var isSigningOut = false
    @State private var signOutError: String?
    /// Profile is a sheet now, not a tab — reached by tapping the avatar on
    /// any main screen's scope banner. It is the root of the sheet's own
    /// navigation stack, so this dismisses the whole sheet.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            List {
                Section {
                    HStack(spacing: 16) {
                        ProfileAvatarView(email: session.userEmail, size: 64)
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
                    NavigationLink("My Household", value: AppNavigation.ProfileDestination.household)
                } footer: {
                    Text("Invite a partner, share accounts, or leave — your data is always yours.")
                }

                // Value links, not destination links: the Profile stack is
                // driven by `AppNavigation.profilePath` so that another screen
                // can push one of these (the FX widget's base-currency note
                // links to Preferences). A destination link inside a
                // path-driven stack pushes without the path knowing, which is
                // how a back button and a programmatic push get out of step.
                Section {
                    NavigationLink("Automations", value: AppNavigation.ProfileDestination.automations)
                    NavigationLink("Preferences", value: AppNavigation.ProfileDestination.preferences)
                    NavigationLink("Data & Privacy", value: AppNavigation.ProfileDestination.dataPrivacy)
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
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
