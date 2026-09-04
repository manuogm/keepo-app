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
    @State var myCategories: [PublicSchema.CategoriesSelect] = []
    @State private var isInviting = false
    @State private var isJoiningFlow = false
    @State private var isLeaving = false
    @State private var isErasing = false
    @State private var showLeaveConfirm = false
    @State private var showEraseConfirm = false
    @State var errorMessage: String?

    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()

            if isLoading {
                ProgressView()
            } else {
                List {
                    householdSection
                    if household != nil {
                        shareSection
                        shareCategoriesSection
                        inviteSection
                        eventsSection
                        leaveSection
                    } else {
                        joinSection
                    }

                    if let errorMessage {
                        FormErrorText(message: errorMessage)
                    }
                }
                .scrollContentBackground(.hidden)
                .refreshable { await load() }
            }
        }
        .navigationTitle("Household")
        .navigationBarTitleDisplayMode(.inline)
        // Keyed on the refresh token like every list in the app, so a
        // pull triggered from anywhere else lands here too.
        .task(id: session.refresh.token) { await load() }
        .sheet(isPresented: $isInviting) {
            InviteFlowView(session: session) { Task { await load() } }
        }
        .sheet(isPresented: $isJoiningFlow) {
            JoinFlowView(session: session) {
                session.refresh.bump()
                Task { await load() }
            }
        }
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
                    Text(memberLabel(member)).foregroundStyle(AppTheme.Palette.textPrimary)
                }
            }
        }
    }

    @ViewBuilder
    private var shareSection: some View {
        Section {
            ForEach(myAccounts, id: \.id) { account in
                Toggle(account.name, isOn: sharedBinding(for: account.id))
                    .tint(AppTheme.Palette.statusPositive)
            }
        } header: {
            Text("Share accounts")
        } footer: {
            Text("A shared account becomes visible and editable by every household member.")
        }
    }

    /// A door into the flow rather than a button that produces a code on the
    /// spot. Choosing what to share and handing over the code are one act,
    /// and the old screen split them: it made a code immediately and left
    /// sharing to a row of toggles further down the same screen.
    @ViewBuilder
    private var inviteSection: some View {
        Section {
            Button("Invite a Partner") { isInviting = true }
                .disabled(members.count >= 2)
        } header: {
            Text("Invite")
        } footer: {
            Text(
                members.count >= 2
                    ? "Your household is full — two members is the limit."
                    : "You'll choose what they can see before the code is created."
            )
        }
    }

    @ViewBuilder
    private var joinSection: some View {
        Section {
            Button("Join a Household") { isJoiningFlow = true }
        } header: {
            Text("Join a Household")
        } footer: {
            Text("You'll see exactly what you're being given before you join.")
        }
    }

    private var eventsSection: some View {
        HouseholdEventsSection(events: events)
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

    private func sharedBinding(for accountId: UUID) -> Binding<Bool> {
        Binding(
            get: { sharedAccountIds.contains(accountId) },
            set: { newValue in
                Task { await setShared(accountId, shared: newValue) }
            }
        )
    }

    func load() async {
        errorMessage = nil
        do {
            let state = try await HouseholdViewLoader.load(session: session)
            household = state.household
            members = state.members
            myAccounts = state.myAccounts
            sharedAccountIds = state.sharedAccountIds
            events = state.events
            if let ownerId = session.profile?.id.uuidString {
                myCategories = (try? await session.dbQueue.read { database in
                    try LocalTableQueries.categories(database, ownerId: ownerId)
                }) ?? []
            }
        } catch {
            // Offline is ambient state, surfaced by the persistent status
            // indicator elsewhere on screen — not a per-fetch red error.
            errorMessage = UserFacingError.isOffline(error) ? nil : UserFacingError.describe(error)
        }
        isLoading = false
    }

    private func createHousehold() async {
        isCreatingHousehold = true
        errorMessage = nil
        do {
            try await HouseholdRepository.create(client: session.client)
            // The household exists on the server; this screen reads the local
            // mirror, so without the pull it keeps rendering "Create
            // Household" and the tap looks like it did nothing. Every other
            // write on this screen already does this — creation was the one
            // that only bumped.
            await session.syncNow()
            await load()
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

/// The household's activity log, as its own view rather than a section of
/// `HouseholdView`'s body — the screen already carries create, share, invite,
/// join, leave and erase, and the log is the one part of it that reads on its
/// own.
private struct HouseholdEventsSection: View {
    let events: [PublicSchema.HouseholdEventsSelect]

    var body: some View {
        if !events.isEmpty {
            Section("Recent Activity") {
                ForEach(events, id: \.id) { event in
                    Text(label(event))
                }
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textSecondary)
            }
        }
    }

    private func label(_ event: PublicSchema.HouseholdEventsSelect) -> String {
        switch event.kind {
        case .memberJoined: return "A member joined"
        case .memberLeft: return "A member left"
        case .memberErased: return "A member erased their data"
        }
    }
}
