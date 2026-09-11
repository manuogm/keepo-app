import KeepoCore
import Observation
import SwiftUI

/// Drives the ten-step ceremony, and is the reason it is allowed to look like
/// a ceremony.
///
/// ## The animation never runs ahead of the truth
///
/// Ten narrated steps sit in front of four pieces of real work: minting the
/// invite, the guest's `accept_invite` (one server transaction that applies
/// both members' account *and* category choices), the category merge, and two
/// sync pulls. So every phase here is one of two things, and never a third:
///
///   * **Gated** — it does not finish until a real call has returned.
///   * **Already true** — the state it describes was made true by an earlier
///     gate in this same run, and the step is naming it for the user.
///
/// What no phase does is claim something that has not happened yet. "Sharing
/// Accounts" is drawn only once the guest is holding a token that carries
/// those accounts; "Receiving Accounts" only once `accept_invite` has come
/// back. The floor duration below is what turns four events into a paced
/// sequence — it can slow a step down, never let one through early.
///
/// ## One narrator
///
/// The owner decides which phase both phones are on and broadcasts it; the
/// guest renders the mirror image of whatever it is told (`Sharing` on one
/// screen is `Receiving` on the other). Two independently-timed animations
/// would drift within a second or two of each other, and two people watching
/// their phones side by side is precisely the situation that makes drift
/// obvious.
@Observable
@MainActor
final class HouseholdSetupCoordinator {
    /// How long the guest spends on a step it is already behind on.
    ///
    /// The owner's first announcements arrive while `accept_invite` is in
    /// flight and nobody is reading the inbox, so the guest begins several
    /// steps in debt. Paying the full floor for each of those keeps the two
    /// phones that far apart for the whole ceremony — which two people
    /// watching side by side read as one of them being stuck. While there is
    /// a backlog the guest spends just enough on a step to see it change,
    /// and converges on the owner within a step or two.
    private static let catchUpFloor: Duration = .milliseconds(220)

    enum Outcome: Equatable {
        case running
        /// Owner only: the data is in, the report can open.
        case readyForReport
        /// Guest only: everything on this side is done and the owner is
        /// reviewing. The house holds at 90% and says who it is waiting for.
        case waitingForOwner
        /// Both: the household is real.
        case finished
        case failed(String)
    }

    private(set) var phase: HouseholdCeremonyPhase = .sharingProfiles
    /// How far through the ceremony both phones are, 0...0.9.
    ///
    /// Held here rather than read off `phase`, because the guest's `phase` is
    /// the **mirror** of what the owner announced and the mirror swaps two
    /// adjacent steps: `.sharingAccounts` (step 2) renders as
    /// `.receivingAccounts` (step 3) and vice versa. Taking the fraction from
    /// the mirrored phase made the guest's percentage read 9, 27, 18, 45, 36,
    /// 54, 72, 63, 81, 90 — advancing, jumping back, advancing — beside an
    /// owner counting smoothly up. The wording is what mirrors; the position
    /// in the sequence is not.
    private(set) var fill: Double = 0
    /// False until the first phase actually begins. The guest sits on this
    /// while it waits for the owner to press Create Household, and the
    /// discovery screen uses it to know when to hand over to the ceremony —
    /// "running" alone would put the guest into a dark, filling house before
    /// anything had started happening.
    private(set) var hasStarted = false
    private(set) var outcome: Outcome = .running
    /// Bumped on every phase change, purely as a `sensoryFeedback` trigger —
    /// a haptic per step is the whole reason the ceremony is felt as well as
    /// watched.
    private(set) var phaseTick = 0

    let pairing: HouseholdPairingSession
    let role: HouseholdPairingIdentity.Role
    var peer: HouseholdPairingIdentity? { pairing.peer }

    /// Internal rather than private for the teardown in
    /// `HouseholdSetupCoordinator+Teardown.swift` — `pairing` and `role`
    /// beside it already are.
    let session: SessionStore
    private let selectedAccountIds: [UUID]
    private let selectedCategoryIds: [UUID]
    /// Kept so the report can tell an original category from a twin that
    /// `accept_invite` auto-created — see `autoMergeCategories()`.
    private(set) var mergedGroupIds: Set<UUID> = []
    /// Whether **this run** brought the household into existence, and whether
    /// anybody ever arrived in it. Together they are what makes an abort safe
    /// to undo: a household the user already had is not this screen's to
    /// dissolve, and one nobody joined is this screen's to discard. The same
    /// two facts, for the same reason, as `HouseholdQRView.discardIfUnused`.
    ///
    /// Internal rather than private only because the teardown that reads them
    /// lives in `HouseholdSetupCoordinator+Teardown.swift`, split off for the
    /// project's file-length lint.
    var didCreateHousehold = false
    var hasJoined = false
    /// Set by `abort()`, so the failure it deliberately causes is not then
    /// reported back to the person who chose it.
    var didAbort = false

    init(
        session: SessionStore,
        pairing: HouseholdPairingSession,
        role: HouseholdPairingIdentity.Role,
        accountIds: [UUID],
        categoryIds: [UUID]
    ) {
        self.session = session
        self.pairing = pairing
        self.role = role
        self.selectedAccountIds = accountIds
        self.selectedCategoryIds = categoryIds
    }

    // MARK: - Running

    func run() async {
        do {
            switch role {
            case .owner: try await runAsOwner()
            case .guest: try await runAsGuest()
            }
        } catch is CancellationError {
            // The user closed the sheet. Nothing to report — the screen is
            // already gone.
        } catch let error as HouseholdLinkError {
            // Our own sentence, already written for this screen.
            // `UserFacingError.describe` deliberately suppresses errors it
            // does not recognise into "Something went wrong", which is the
            // right default for a Postgres failure and the wrong one here.
            await report(error.message)
        } catch {
            await report(UserFacingError.describe(error))
        }
    }

    /// The single place `outcome` is written from outside the run.
    ///
    /// `outcome` stays `private(set)`: the run is what decides how the
    /// ceremony went, and a settable outcome is a screen any caller could
    /// lie to. The teardown next door needs exactly this one word and gets
    /// exactly this one word.
    func conclude(_ message: String) {
        outcome = .failed(message)
    }

    /// Called by the report when the owner presses Finish. Both houses fill
    /// the rest of the way together.
    func finish() async {
        // The one irreversible moment in the whole flow. Everything up to here
        // — the shares, the merges, a pruned tag's labels — was undoable, and
        // this is what gives that up.
        try? await HouseholdRepository.finalizeHousehold(client: session.client)
        await session.syncNow()
        session.refresh.bump()
        pairing.send(.finished)
        outcome = .finished
    }

    // MARK: - The owner's run

    private func runAsOwner() async throws {
        try await step(.sharingProfiles) {
            try await self.ensureHousehold()
            let token = try await HouseholdRepository.createInvite(
                client: self.session.client,
                accountIds: self.selectedAccountIds,
                categoryIds: self.selectedCategoryIds
            )
            self.pairing.send(.invite(token: token))
        }

        // Already true: the token the guest is now holding carries exactly
        // these accounts, and `accept_invite` applies them from it.
        try await step(.sharingAccounts) {}

        // The gate that matters. `accept_invite` returning is the moment the
        // household actually has two members and both sets of shares.
        try await step(.receivingAccounts) {
            try await self.waitForJoin()
            self.hasJoined = true
        }

        // Already true — the same transaction applied both members' category
        // choices.
        try await step(.sharingCategories) {}
        try await step(.receivingCategories) {}

        try await step(.mergingCategories) {
            await self.session.syncNow()
            try await self.autoMergeCategories()
        }

        // Tag visibility is derived from account sharing (`can_read_tag`), so
        // by here it is already true on the server; the pull below is what
        // brings the rows onto this phone.
        try await step(.sharingTags) {}
        try await step(.receivingTags) {
            await self.session.syncNow()
        }
        // No server work, and honestly so: tags are never merged
        // automatically. Deciding two tags are one is a judgement about
        // somebody's history, and it is made in the report, by hand.
        try await step(.mergingTags) {}

        try await step(.buildingHousehold) {
            await self.session.syncNow()
            self.session.refresh.bump()
        }

        outcome = .readyForReport

        // The report has no clock on it — the owner can sit with it for
        // minutes. Nobody is reading the inbox during that, so a guest who
        // backs out would leave the owner reviewing a household the server
        // has already dissolved, and finding out one failed RPC at a time.
        // The loop ends on its own when the link is torn down, which resumes
        // the waiter with nil.
        while let message = await pairing.nextMessage() {
            if case .cancelled(let reason) = message {
                throw HouseholdLinkError.stopped(reason)
            }
        }
    }

    // MARK: - The guest's run

    private func runAsGuest() async throws {
        let token = try await waitForToken()

        // The guest's whole contribution is one call, and it is made behind
        // the first step rather than spread across the narration, because
        // pretending otherwise would be the animation lying about which
        // phone is doing what.
        try await HouseholdRepository.acceptInvite(
            client: session.client,
            token: token,
            accountIds: selectedAccountIds,
            categoryIds: selectedCategoryIds
        )
        hasJoined = true
        await session.syncNow()
        session.refresh.bump()
        pairing.send(.joined)

        // From here the owner narrates. Every phase it announces is drawn as
        // this side's mirror of it.
        while let message = await pairing.nextMessage() {
            switch message {
            case .phase(let announced):
                try await renderPhase(announced)
                if announced == .buildingHousehold {
                    await session.syncNow()
                    outcome = .waitingForOwner
                }
            case .finished:
                await session.syncNow()
                session.refresh.bump()
                outcome = .finished
                return
            case .cancelled(let reason):
                await report(
                    reason ?? "\(peer?.resolvedName ?? "The other phone") stopped before the household was built."
                )
                return
            case .identity, .invite, .joined:
                continue
            }
        }
    }

    // MARK: - Steps

    /// Runs `work`, holds the phase on screen for at least its own floor,
    /// then tells the other phone where we are.
    ///
    /// The floor is measured around the work rather than after it, so a step
    /// whose call takes a second does not then sit for another half — the
    /// pacing is a minimum, not an addition. Each phase carries its own (see
    /// `HouseholdCeremonyPhase.minimumDuration`), so the steps that are only
    /// naming something already true go by quickly and the ones with a server
    /// call behind them are given room.
    private func step(_ next: HouseholdCeremonyPhase, work: @escaping () async throws -> Void) async throws {
        // Checked here rather than by awaiting the inbox, because between
        // `waitForJoin` and the end of the ceremony nobody is awaiting it —
        // the owner is inside these closures doing server work. A guest who
        // backs out mid-ceremony would otherwise sit unread in `pending`
        // while this side went on building a household that no longer has
        // two members in it.
        if pairing.didPeerStop { throw HouseholdLinkError.stopped(pairing.peerStopReason) }
        setPhase(next, fill: next.fill)
        if role == .owner { pairing.send(.phase(next)) }

        let startedAt = ContinuousClock.now
        try await work()
        let remaining = next.minimumDuration - startedAt.duration(to: ContinuousClock.now)
        if remaining > .zero { try await Task.sleep(for: remaining) }
    }

    private func setPhase(_ next: HouseholdCeremonyPhase, fill: Double) {
        hasStarted = true
        // Taken from the announced step even when the drawn step is its
        // mirror, and never allowed to fall — the house fills, it does not
        // breathe.
        self.fill = max(self.fill, fill)
        guard next != phase || phaseTick == 0 else { return }
        phase = next
        phaseTick += 1
    }

    /// The guest's side of the pacing, and the only place the mirror is
    /// applied: the **wording** flips (`Sharing` here is `Receiving` there),
    /// the position in the sequence does not.
    ///
    /// The owner's early announcements arrive while `accept_invite` is still
    /// in flight and nobody is reading the inbox, so they are buffered and
    /// then all arrive at once. Rendered as they land, three steps would flash
    /// past in a single frame. The same floor the owner paces itself with is
    /// applied here on the way out of the buffer, so both phones spend the
    /// same time on the same step.
    private func renderPhase(_ announced: HouseholdCeremonyPhase) async throws {
        let startedAt = ContinuousClock.now
        setPhase(announced.mirrored, fill: announced.fill)
        // A step the owner has already moved past is one this side is behind
        // on, not one to dwell over. `announced.minimumDuration` is the pace
        // the owner is keeping; the backlog is the debt.
        let floor = pairing.hasBacklog ? Self.catchUpFloor : announced.minimumDuration
        let remaining = floor - startedAt.duration(to: ContinuousClock.now)
        if remaining > .zero { try await Task.sleep(for: remaining) }
    }

    // MARK: - Waiting on the other phone

    private func waitForToken() async throws -> String {
        while let message = await pairing.nextMessage() {
            switch message {
            case .invite(let token): return token
            case .cancelled(let reason): throw HouseholdLinkError.stopped(reason)
            // The owner announces the first phase *before* it mints the
            // token, so this arrives first. Dropping it — which the obvious
            // `default: continue` does — leaves the guest on the discovery
            // screen until the token lands, and the two phones visibly start
            // the ceremony at different moments.
            case .phase(let announced): try await renderPhase(announced)
            case .identity, .joined, .finished: continue
            }
        }
        throw HouseholdLinkError.lost
    }

    private func waitForJoin() async throws {
        while let message = await pairing.nextMessage() {
            switch message {
            case .joined: return
            case .cancelled(let reason): throw HouseholdLinkError.stopped(reason)
            default: continue
            }
        }
        throw HouseholdLinkError.lost
    }

    // MARK: - Work

    /// A household may already exist — `create_household` is what the old
    /// screen's button called, and a user who created one and never invited
    /// anybody still has a single-member household sitting there.
    private func ensureHousehold() async throws {
        guard let userId = session.profile?.id.uuidString else { return }
        let existing = try? await session.dbQueue.read { database in
            try LocalTableQueries.myHousehold(database, userId: userId)
        }
        guard existing == nil else { return }
        try await HouseholdRepository.create(client: session.client)
        didCreateHousehold = true
        await session.syncNow()
    }

    /// The automatic pass, which lives in `HouseholdAutoMerge` because the QR
    /// fallback has to run exactly the same one without a coordinator.
    private func autoMergeCategories() async throws {
        mergedGroupIds = try await HouseholdAutoMerge.run(
            session: session, selectedCategoryIds: selectedCategoryIds
        )
    }
}
