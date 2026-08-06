import KeepoCore
import SwiftUI

/// Phase 7's Household section: create a household, share/unshare the
/// caller's own accounts into it, see who else is a member. Invites/leave
/// (Phase 19) aren't here yet — the running app is single-member-household
/// until then; a second member currently only exists via the pgTAP suite or
/// a manual `household_members` insert against the local stack.
struct SettingsView: View {
    let session: SessionStore

    @State private var household: PublicSchema.HouseholdsSelect?
    @State private var members: [PublicSchema.HouseholdMembersSelect] = []
    @State private var myAccounts: [PublicSchema.AccountsSelect] = []
    @State private var sharedAccountIds: Set<UUID> = []
    @State private var isLoading = true
    @State private var isCreatingHousehold = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color("BGCanvas").ignoresSafeArea()

            if isLoading {
                ProgressView()
            } else {
                List {
                    Section("Household") {
                        if household == nil {
                            Button {
                                Task { await createHousehold() }
                            } label: {
                                if isCreatingHousehold {
                                    ProgressView()
                                } else {
                                    Text("Create Household")
                                }
                            }
                            .disabled(isCreatingHousehold)
                        } else {
                            ForEach(members, id: \.userId) { member in
                                Text(memberLabel(member))
                                    .foregroundStyle(Color("TextPrimary"))
                            }
                        }
                    }

                    if household != nil {
                        Section {
                            ForEach(myAccounts, id: \.id) { account in
                                Toggle(account.name, isOn: sharedBinding(for: account.id))
                            }
                        } header: {
                            Text("Share accounts")
                        } footer: {
                            Text("A shared account becomes visible and editable by every household member.")
                        }
                    }

                    Section {
                        NavigationLink("Recurring Transactions") {
                            RecurringRulesView(session: session)
                        }
                    } footer: {
                        Text("Rent, subscriptions, salary — anything on a schedule logs itself automatically.")
                    }

                    Section {
                        NavigationLink("Budgets") {
                            BudgetsView(session: session)
                        }
                    } footer: {
                        Text("Set a monthly spending cap overall or per category.")
                    }

                    Section {
                        NavigationLink("Set Up Apple Pay Capture") {
                            WalletAutomationGuideView()
                        }
                    } footer: {
                        Text("Log Apple Pay purchases automatically via a Shortcuts automation on the Wallet trigger.")
                    }

                    Section {
                        NavigationLink("Security") {
                            SecuritySettingsView(session: session)
                        }
                    } footer: {
                        Text("Base currency, biometric step-up, and a recovery email.")
                    }

                    #if DEBUG
                    Section("Developer") {
                        NavigationLink("Simulate Capture") {
                            SimulateCaptureView(session: session)
                        }
                    }
                    #endif

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .scrollContentBackground(.hidden)
                .refreshable { await load() }
            }
        }
        .navigationTitle("Settings")
        .task(id: session.refresh.token) { await load() }
    }

    private func memberLabel(_ member: PublicSchema.HouseholdMembersSelect) -> String {
        member.userId == session.profile?.id ? "You" : "Household member"
    }

    private func sharedBinding(for accountId: UUID) -> Binding<Bool> {
        Binding(
            get: { sharedAccountIds.contains(accountId) },
            set: { newValue in
                Task { await setShared(accountId, shared: newValue) }
            }
        )
    }

    private func load() async {
        errorMessage = nil
        do {
            let fetchedHousehold = try await HouseholdRepository.fetchMine(client: session.client)
            household = fetchedHousehold

            if fetchedHousehold != nil {
                async let membersResult = HouseholdRepository.fetchMembers(client: session.client)
                async let sharedResult = HouseholdRepository.fetchSharedAccountIds(client: session.client)
                members = try await membersResult
                sharedAccountIds = try await sharedResult
            } else {
                members = []
                sharedAccountIds = []
            }

            if let userId = session.profile?.id {
                myAccounts = try await AccountRepository.fetchAllOwnedByMe(client: session.client, ownerId: userId)
            }
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isLoading = false
    }

    private func createHousehold() async {
        isCreatingHousehold = true
        errorMessage = nil
        do {
            try await HouseholdRepository.create(client: session.client)
            session.refresh.bump()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isCreatingHousehold = false
    }

    private func setShared(_ accountId: UUID, shared: Bool) async {
        errorMessage = nil
        do {
            if shared {
                try await HouseholdRepository.share(client: session.client, accountId: accountId)
            } else {
                try await HouseholdRepository.unshare(client: session.client, accountId: accountId)
            }
            session.refresh.bump()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
    }
}
