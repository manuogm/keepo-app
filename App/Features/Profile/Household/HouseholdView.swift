import KeepoCore
import SwiftUI

/// The Household screen: a blank state with two doors, or the household you
/// already have.
///
/// Reached from the avatar, through Profile. One screen with two entirely
/// different bodies rather than two screens, because "do I have a household"
/// is a fact about the user rather than a place they navigate to — and the
/// day they build one, the screen they were looking at should become the
/// screen that describes it, in place.
struct HouseholdView: View {
    let session: SessionStore
    let avatars: AvatarStore

    @State private var snapshot = HouseholdSnapshot()
    @State private var peerAvatar: UIImage?
    @State private var isLoading = true
    @State private var setupRole: HouseholdPairingIdentity.Role?
    @State private var isShowingInfo = false
    @State private var isShowingMember = false
    @State private var isShowingLeaveConfirm = false
    /// Removing the other member and leaving are the **same operation**:
    /// `leave_household()` forks every shared account into two private copies
    /// and drops the caller's membership, leaving the other member alone in a
    /// single-member household. From either side the household ends and both
    /// people keep everything.
    ///
    /// So this is only a wording flag — which of the two sentences the
    /// confirmation shows. Presenting "Remove from Household" as something
    /// other than what it is, a mutual split rather than a one-sided eviction
    /// that leaves the remover in possession, would be a promise the schema
    /// does not make.
    @State private var isRemoving = false
    @State private var isLeaving = false
    @State private var isShowingDissolved = false
    @AppStorage(AppSettingsKeys.lastKnownHouseholdId) private var lastKnownHouseholdId = ""
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()

            if isLoading {
                ProgressView()
            } else if snapshot.hasHousehold {
                household
            } else {
                HouseholdBlankState(
                    onCreate: { setupRole = .owner },
                    onJoin: { setupRole = .guest }
                )
            }
        }
        .navigationTitle("Household")
        .navigationBarTitleDisplayMode(.inline)
        // The info affordance belongs **to the title**, not to the corner.
        // As a top-right bar button it read as a second action competing with
        // the back chevron; beside the word it reads as what it is — a
        // footnote on the thing named next to it. `.principal` is the only
        // placement that can put anything alongside the title.
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text("Household")
                        .font(AppTheme.Typography.rowTitle)
                        .foregroundStyle(AppTheme.Palette.textPrimary)
                    if snapshot.hasHousehold {
                        Button { isShowingInfo = true } label: {
                            // Padding **inside** the label, not `.hitTarget()`
                            // outside the button: that modifier works by
                            // overlaying a hit-testable `Color.clear`, which
                            // on a `Button` lands *on top of* it and swallows
                            // every tap. The glyph rendered and did nothing.
                            KeepoIcon(name: "icon-info", size: AppTheme.Size.glyphSmall)
                                .foregroundStyle(AppTheme.Palette.textSecondary)
                                .padding(AppTheme.Spacing.s)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("About households")
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingInfo) {
            HouseholdInfoSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isShowingDissolved) {
            HouseholdDissolvedSheet(partner: dissolvedPartnerName)
                .presentationDetents([.medium])
                .interactiveDismissDisabled()
        }
        .task(id: session.refresh.token) { await load() }
        // `item:` rather than two booleans: Create and Join are the same
        // sheet with a different role, and two flags would make "both true"
        // representable.
        .fullScreenCover(item: $setupRole) { role in
            HouseholdSetupFlow(session: session, avatars: avatars, role: role) {
                session.refresh.bump()
                Task { await load() }
            }
        }
        .sheet(isPresented: $isShowingMember) {
            if let peer = snapshot.peer {
                HouseholdMemberSheet(
                    member: peer,
                    image: peerAvatar,
                    onRemove: {
                        isShowingMember = false
                        isRemoving = true
                        isShowingLeaveConfirm = true
                    }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
        .confirmationDialog(
            isRemoving ? "Remove \(peerName) from your household?" : "Leave this household?",
            isPresented: $isShowingLeaveConfirm,
            titleVisibility: .visible
        ) {
            Button(isRemoving ? "Remove" : "Leave", role: .destructive) {
                Task { await leave() }
            }
            Button("Cancel", role: .cancel) { isRemoving = false }
        } message: {
            Text(
                "Every shared account splits into two private copies — one each. Nothing is lost, "
                    + "and neither of you keeps access to the other's."
            )
        }
    }

    private var peerName: String {
        snapshot.peer?.displayName ?? snapshot.peer?.email ?? "your partner"
    }

    // MARK: - The household

    private var household: some View {
        ScrollView {
            VStack(spacing: AppTheme.Spacing.l) {
                HouseholdContainer(
                    owner: memberView(isMe: amOwner),
                    guest: memberView(isMe: !amOwner),
                    since: since,
                    onTapOther: { isShowingMember = true }
                )
                .padding(.vertical, AppTheme.Spacing.m)

                HouseholdSummaryCard(session: session, snapshot: snapshot) {
                    Task { await load() }
                }

                DestructiveActionButton(title: "Leave Household", isEnabled: !isLeaving) {
                    isRemoving = false
                    isShowingLeaveConfirm = true
                }
                .padding(.top, AppTheme.Spacing.s)

                if let errorMessage { FormErrorText(message: errorMessage) }
            }
            .padding(.horizontal, AppTheme.Spacing.l)
            .padding(.bottom, AppTheme.Spacing.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .refreshable { await load() }
    }

    /// The owner sits on the left of the container, always — it is the same
    /// picture on both phones, which is what makes it a picture of the
    /// household rather than of the viewer.
    private var amOwner: Bool {
        snapshot.peer.map { !$0.isOwner } ?? true
    }

    private func memberView(isMe: Bool) -> HouseholdMemberView {
        isMe
            ? HouseholdMemberView(
                name: session.profile?.displayName ?? session.userEmail ?? "You",
                image: avatars.image,
                isMe: true
            )
            : HouseholdMemberView(name: peerName, image: peerAvatar, isMe: false)
    }

    /// "Since Sep 26" — month and two-digit year, per the spec. Money rule
    /// 5's reasoning applied to a date: an unparseable timestamp has no month,
    /// and inventing one would put a confident wrong answer on the badge.
    private var since: String? {
        guard let createdAt = snapshot.household?.createdAt,
              let date = PostgresDate.date(fromTimestamp: createdAt) else { return nil }
        return "Since " + date.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
    }

    // MARK: - Data

    /// Kept across the dissolution so the notice can name who left — by the
    /// time it shows, the household and its member row are both gone.
    @State private var dissolvedPartnerName = ""

    private func load() async {
        errorMessage = nil
        snapshot = await HouseholdDataLoader.load(session: session)
        noticeDissolutionIfNeeded()
        await avatars.load(path: session.profile?.avatarPath, client: session)
        // The other member's face, now that a household exists and
        // `avatars_select` admits it. Its own store, because `AvatarStore`
        // holds exactly one image — the signed-in user's — and pointing it at
        // somebody else would swap the face on every screen in the app.
        peerAvatar = await HouseholdPeerAvatar.load(
            path: snapshot.peer?.avatarPath, session: session
        )
        isLoading = false
    }

    /// The household is gone from the mirror but this device was holding one:
    /// the other member left, and leaving now ends it for both.
    ///
    /// Not shown to whoever pressed Leave — `leave()` clears the marker before
    /// reloading, so `previous` is already empty by the time this runs. They
    /// know; they did it.
    private func noticeDissolutionIfNeeded() {
        let previous = lastKnownHouseholdId
        if let current = snapshot.household?.id.uuidString {
            lastKnownHouseholdId = current
            dissolvedPartnerName = peerName
        } else if !previous.isEmpty {
            lastKnownHouseholdId = ""
            isShowingDissolved = true
        }
    }

    private func leave() async {
        isLeaving = true
        errorMessage = nil
        // Cleared up front: this device is about to lose its household on
        // purpose, and the notice is for the member who did not choose it.
        lastKnownHouseholdId = ""
        do {
            try await session.stepUp(reason: "Confirm it's you to leave this household")
            try await HouseholdRepository.leave(client: session.client)
            await session.syncNow()
            session.refresh.bump()
            await load()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isLeaving = false
        isRemoving = false
    }
}

extension HouseholdPairingIdentity.Role: Identifiable {
    public var id: String { rawValue }
}
