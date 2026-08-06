import KeepoCore
import SwiftUI

/// Phase 7 built create/share/unshare; Phase 19 adds the lifecycle — invite,
/// accept, leave (fork), erase. Leave/erase require a fresh step-up check
/// immediately before the RPC, same rule Phase 17 applies to export.
struct HouseholdView: View {
    let session: SessionStore

    @State private var household: PublicSchema.HouseholdsSelect?
    @State private var members: [PublicSchema.HouseholdMembersSelect] = []
    @State private var myAccounts: [PublicSchema.AccountsSelect] = []
    @State private var sharedAccountIds: Set<UUID> = []
    @State private var events: [PublicSchema.HouseholdEventsSelect] = []
    @State private var isLoading = true
    @State private var isCreatingHousehold = false
    @State private var isCreatingInvite = false
    @State private var generatedToken: String?
    @State private var joinTokenText = ""
    @State private var isJoining = false
    @State private var isLeaving = false
    @State private var isErasing = false
    @State private var showLeaveConfirm = false
    @State private var showEraseConfirm = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color("BGCanvas").ignoresSafeArea()

            if isLoading {
                ProgressView()
            } else {
                List {
                    householdSection
                    if household != nil {
                        shareSection
                        inviteSection
                        eventsSection
                        leaveSection
                    } else {
                        joinSection
                    }

                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    }
                }
                .scrollContentBackground(.hidden)
                .refreshable { await load() }
            }
        }
        .navigationTitle("Household")
        .task { await load() }
        .confirmationDialog(
            "Leave this household?", isPresented: $showLeaveConfirm, titleVisibility: .visible
        ) {
            Button("Leave", role: .destructive) { Task { await leave() } }
        } message: {
            Text("Every shared account forks into your own private copy — nothing is lost, but sharing ends.")
        }
        .confirmationDialog(
            "Erase your data?", isPresented: $showEraseConfirm, titleVisibility: .visible
        ) {
            Button("Erase", role: .destructive) { Task { await erase() } }
        } message: {
            Text("Forks your accounts like leaving does, then scrubs merchant names and filenames from your own copy.")
        }
    }

    @ViewBuilder
    private var householdSection: some View {
        Section("Household") {
            if household == nil {
                Button {
                    Task { await createHousehold() }
                } label: {
                    if isCreatingHousehold { ProgressView() } else { Text("Create Household") }
                }
                .disabled(isCreatingHousehold)
            } else {
                ForEach(members, id: \.userId) { member in
                    Text(memberLabel(member)).foregroundStyle(Color("TextPrimary"))
                }
            }
        }
    }

    @ViewBuilder
    private var shareSection: some View {
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

    @ViewBuilder
    private var inviteSection: some View {
        Section {
            if let generatedToken {
                Text(generatedToken).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Text("Share this code — it expires in 7 days and works once.")
                    .font(.footnote).foregroundStyle(Color("TextSecondary"))
            } else {
                Button {
                    Task { await createInvite() }
                } label: {
                    if isCreatingInvite { ProgressView() } else { Text("Invite a Partner") }
                }
                .disabled(isCreatingInvite || members.count >= 2)
            }
        } header: {
            Text("Invite")
        }
    }

    @ViewBuilder
    private var joinSection: some View {
        Section {
            TextField("Invite code", text: $joinTokenText).autocorrectionDisabled()
            Button {
                Task { await join() }
            } label: {
                if isJoining { ProgressView() } else { Text("Join Household") }
            }
            .disabled(isJoining || joinTokenText.isEmpty)
        } header: {
            Text("Join a Household")
        }
    }

    @ViewBuilder
    private var eventsSection: some View {
        if !events.isEmpty {
            Section("Recent Activity") {
                ForEach(events, id: \.id) { event in
                    Text(eventLabel(event)).font(.footnote).foregroundStyle(Color("TextSecondary"))
                }
            }
        }
    }

    @ViewBuilder
    private var leaveSection: some View {
        Section {
            Button("Leave Household", role: .destructive) {
                showLeaveConfirm = true
            }
            .disabled(isLeaving || isErasing)

            Button("Erase My Data", role: .destructive) {
                showEraseConfirm = true
            }
            .disabled(isLeaving || isErasing)
        }
    }

    private func memberLabel(_ member: PublicSchema.HouseholdMembersSelect) -> String {
        member.userId == session.profile?.id ? "You" : "Household member"
    }

    private func eventLabel(_ event: PublicSchema.HouseholdEventsSelect) -> String {
        switch event.kind {
        case .memberJoined: return "A member joined"
        case .memberLeft: return "A member left"
        case .memberErased: return "A member erased their data"
        }
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
            let state = try await HouseholdViewLoader.load(session: session)
            household = state.household
            members = state.members
            myAccounts = state.myAccounts
            sharedAccountIds = state.sharedAccountIds
            events = state.events
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

    private func createInvite() async {
        isCreatingInvite = true
        errorMessage = nil
        do {
            generatedToken = try await HouseholdRepository.createInvite(client: session.client)
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isCreatingInvite = false
    }

    private func join() async {
        isJoining = true
        errorMessage = nil
        do {
            try await HouseholdRepository.acceptInvite(client: session.client, token: joinTokenText)
            joinTokenText = ""
            session.refresh.bump()
            await load()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isJoining = false
    }

    private func leave() async {
        isLeaving = true
        errorMessage = nil
        do {
            try await session.stepUp(reason: "Confirm it's you to leave this household")
            try await HouseholdRepository.leave(client: session.client)
            session.refresh.bump()
            await load()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isLeaving = false
    }

    private func erase() async {
        isErasing = true
        errorMessage = nil
        do {
            try await session.stepUp(reason: "Confirm it's you to erase your data")
            try await HouseholdRepository.eraseOwnAccount(client: session.client)
            session.refresh.bump()
            await load()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isErasing = false
    }
}
