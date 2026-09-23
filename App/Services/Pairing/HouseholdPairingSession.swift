import Foundation
import KeepoCore
import MultipeerConnectivity
import Observation
import UIKit

/// The link between two phones held next to each other, while a household is
/// being built.
///
/// **MultipeerConnectivity**, which is the framework AirDrop-style discovery
/// is built on: Bluetooth plus peer-to-peer Wi-Fi, negotiated by the system,
/// with a range of a few metres. That range *is* the proximity guarantee.
/// There is no distance API here — `NearbyInteraction` could give a real
/// figure in metres but needs a U1 chip on both phones, and a pairing flow
/// that silently fails on an iPhone SE is worse than one that trusts the
/// radio's own reach.
///
/// ## The two roles are not symmetrical
///
/// The owner **advertises** and the guest **browses**, and only the guest
/// ever sends an invitation. Both sides could do both — and the first sketch
/// of this did — but then two phones discover each other simultaneously,
/// both invite, and `MCSession` ends up with two half-open connections
/// racing to the same peer. The asymmetry costs nothing (the owner is
/// waiting either way) and removes the race entirely.
///
/// ## Permissions
///
/// iOS 14 onward gates this behind the local-network prompt, which is why
/// `NSLocalNetworkUsageDescription` and `NSBonjourServices` are in
/// `project.yml`. There is **no API that reports the answer**: a denied
/// prompt looks exactly like an empty room — the browser simply never calls
/// `foundPeer`. That is the whole reason the discovery screen has a timeout
/// and a QR fallback rather than an error state; see
/// `HouseholdDiscoveryView`.
@Observable
@MainActor
final class HouseholdPairingSession: NSObject {
    /// Bonjour service type: 1–15 characters, lowercase ASCII, digits and
    /// hyphens only, and it must match `NSBonjourServices` in the Info.plist
    /// exactly or the browser starts and finds nothing, forever, with no
    /// error. Changing this string means changing it in `project.yml` too.
    static let serviceType = "keepo-house"

    enum State: Equatable {
        /// Radios up, nobody found yet.
        case searching
        /// Connected, and waiting on the code. The owner is waiting for the
        /// guest to type theirs; the guest is being asked for it. **Neither
        /// side has sent its identity yet** — that is what the code buys.
        case verifying
        /// Connected, code accepted, and both identities exchanged. The
        /// discovery screen draws the other person's face from here.
        case paired(HouseholdPairingIdentity)
        /// The link dropped after being established. Distinct from
        /// `searching` because the screen has something to apologise for.
        case lost
        case failed(String)
    }

    private(set) var state: State = .searching
    /// Set once the peer's identity lands, and kept across a `lost` so the
    /// ceremony can still name who it was building with.
    private(set) var peer: HouseholdPairingIdentity?

    /// The owner's code and its attempt budget; nil on the guest's side.
    /// Held on the session, not the connection — a budget the peer refills
    /// by hanging up is no budget. See `HouseholdPairingChallenge`.
    private var challenge: HouseholdPairingChallenge?

    /// The digits to put on screen, owner-side.
    var pairingCode: HouseholdPairingCode? { challenge?.code }
    /// Guest-side: what to say under the field after a refused code. Nil
    /// before the first attempt and after a correct one.
    private(set) var codeRejection: String?

    /// Messages from the other phone, in arrival order.
    ///
    /// A one-at-a-time `await` rather than an `AsyncStream`, because the
    /// ceremony reads its inbox in two distinct shapes — the owner awaits one
    /// specific message mid-sequence, then the guest loops over the rest —
    /// and `AsyncStream` supports exactly one iterator for its whole life.
    /// Taking a second one is undefined behaviour, and the failure mode is a
    /// message silently going to the iterator nobody is reading any more.
    ///
    /// Anything that arrives with no reader waiting is buffered, so a fast
    /// peer can never outrun the ceremony's own pacing.
    private var pending: [HouseholdPairingMessage] = []
    private var waiter: CheckedContinuation<HouseholdPairingMessage?, Never>?
    private var isStopped = false

    /// Set the instant a `.cancelled` lands, whether or not anybody is
    /// reading.
    ///
    /// The owner spends most of the ceremony inside `step`, doing server
    /// work — it is not awaiting a message between `waitForJoin` and the end,
    /// so a guest who backs out mid-ceremony would sit in `pending`,
    /// unnoticed, while the owner carried on building a household that no
    /// longer has two members. A flag the running side can read without
    /// awaiting is what makes the abort travel in both directions.
    private(set) var didPeerStop = false
    private(set) var peerStopReason: String?

    /// Whether another message is already waiting behind the one just read.
    ///
    /// The guest paces itself off a floor per step, and the owner's early
    /// announcements arrive while `accept_invite` is still in flight and
    /// nobody is reading the inbox — so they all land at once and the guest
    /// starts the ceremony several steps in debt, paying a full floor for
    /// each one it works through and never catching up. Reading the backlog
    /// is what lets it shorten the floor until it is level with the owner
    /// again. See `HouseholdSetupCoordinator.renderPhase`.
    var hasBacklog: Bool { !pending.isEmpty }

    /// The next message, or `nil` once the link is closed for good.
    func nextMessage() async -> HouseholdPairingMessage? {
        if !pending.isEmpty { return pending.removeFirst() }
        if isStopped { return nil }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    private func deliver(_ message: HouseholdPairingMessage) {
        if case .cancelled(let reason) = message {
            didPeerStop = true
            peerStopReason = reason
        }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: message)
        } else {
            pending.append(message)
        }
    }

    private let identity: HouseholdPairingIdentity
    private let localPeerID: MCPeerID
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    /// The one peer this session will talk to. Set on the first successful
    /// connection and never changed — a household is two people, and a third
    /// phone joining the conversation is a bug, not a feature.
    private var connectedPeer: MCPeerID?

    init(identity: HouseholdPairingIdentity) {
        self.identity = identity
        // Only the owner holds one. The guest is told it out loud.
        self.challenge = identity.role == .owner ? HouseholdPairingChallenge() : nil
        // `MCPeerID`'s display name is capped at 63 bytes and the initialiser
        // traps above it. A name is user input, so it is measured in UTF-8
        // bytes and cut there rather than trusted to be short.
        self.localPeerID = MCPeerID(displayName: Self.peerName(identity.resolvedName))
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        let session = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        self.session = session

        switch identity.role {
        case .owner:
            // `discoveryInfo` is how a browsing guest tells a household owner
            // from any other Keepo user on the same Wi-Fi. Values must be
            // short — the whole dictionary rides in the Bonjour TXT record.
            let advertiser = MCNearbyServiceAdvertiser(
                peer: localPeerID,
                discoveryInfo: ["role": HouseholdPairingIdentity.Role.owner.rawValue, "v": "1"],
                serviceType: Self.serviceType
            )
            advertiser.delegate = self
            advertiser.startAdvertisingPeer()
            self.advertiser = advertiser
        case .guest:
            let browser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: Self.serviceType)
            browser.delegate = self
            browser.startBrowsingForPeers()
            self.browser = browser
        }
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        advertiser = nil
        browser = nil
        session = nil
        connectedPeer = nil
        isStopped = true
        // Anything still awaiting a message gets `nil` rather than hanging.
        // A ceremony left suspended on a peer that has gone is a screen the
        // user cannot leave.
        waiter?.resume(returning: nil)
        waiter = nil
    }

    // MARK: - Sending

    /// Fire-and-forget by design. `.reliable` guarantees ordering and
    /// delivery, so a failure here means the link is gone — which the
    /// delegate is about to report anyway, and reporting it twice would have
    /// the screen apologising in two places at once.
    func send(_ message: HouseholdPairingMessage) {
        guard let session, let connectedPeer, let data = try? JSONEncoder().encode(message) else { return }
        try? session.send(data, toPeers: [connectedPeer], with: .reliable)
    }

    // MARK: - What the delegates are allowed to ask
    /// The session to hand an arriving invitation, or nil to refuse it.
    ///
    /// **Accepted without asking the user**, as it always was — but what
    /// accepting grants is now an open pipe and nothing else, until the code
    /// is answered. A system "Accept?" alert over a screen that says
    /// "Looking for nearby devices" would ask a question already answered by
    /// starting the flow and standing next to the other phone.
    func sessionForIncomingInvitation() -> MCSession? {
        connectedPeer == nil ? session : nil
    }

    /// The session to invite a found owner into, or nil if already busy.
    func sessionForOutgoingInvitation() -> MCSession? {
        connectedPeer == nil ? session : nil
    }

    /// A radio that would not start. Same sentence either way, because the
    /// user's fix is the same and the underlying `NSError` names a framework
    /// they have never heard of.
    func radioFailed() {
        state = .failed(Self.radioFailureMessage)
    }

    static let radioFailureMessage =
        "Keepo could not start looking for nearby devices. Check that Bluetooth and Wi-Fi are on, "
        + "and that Keepo is allowed to find devices on your local network in Settings."

    // MARK: - The code

    /// Guest side. Sends what the user typed for the owner to judge; no
    /// local format check, because the owner is the only side that can say
    /// whether a code is right and a second copy would drift.
    func submitCode(_ entered: String) {
        guard identity.role == .guest else { return }
        codeRejection = nil
        send(.codeProof(code: entered))
    }

    /// Handles the three code messages and reports whether it consumed one;
    /// they are the session's own and never reach the ceremony.
    private func handleCodeMessage(_ message: HouseholdPairingMessage) -> Bool {
        switch message {
        case .codeProof(let code):
            judge(code)
        case .codeAccepted:
            // Guest side only, and the role guard is load bearing: an owner
            // that acted on this would answer a message any peer can send by
            // handing over its identity — the very gate this closes.
            guard identity.role == .guest else { return true }
            codeRejection = nil
            send(.identity(identity))
        case .codeRejected(let remaining):
            guard identity.role == .guest else { return true }
            codeRejection = remaining == 1
                ? "That code isn't right. One more try before you have to start again."
                : "That code isn't right. \(remaining) tries left."
        default:
            return false
        }
        return true
    }

    /// Owner side. Spends a try; running out ends the session, because
    /// retrying in place would refund the guesses just spent.
    private func judge(_ entered: String) {
        guard identity.role == .owner, challenge != nil else { return }

        switch challenge?.judge(entered) {
        case .accepted:
            send(.codeAccepted)
            send(.identity(identity))
        case .rejected(let remaining):
            send(.codeRejected(attemptsRemaining: remaining))
        case .exhausted, .none:
            send(.cancelled(reason: Self.tooManyAttemptsMessage))
            state = .failed(Self.tooManyAttemptsMessage)
            stop()
        }
    }
    static let tooManyAttemptsMessage = "Too many wrong codes. Keepo stopped the pairing to keep "
        + "your household safe — start again and Keepo will give you a new code."

    // MARK: - Identity

    /// The local user's identity payload, with their avatar attached when one
    /// exists and is small enough to be worth sending.
    static func identity(
        for role: HouseholdPairingIdentity.Role, session: SessionStore, avatar: UIImage?
    ) -> HouseholdPairingIdentity? {
        guard let userId = session.profile?.id else { return nil }
        return HouseholdPairingIdentity(
            userId: userId,
            displayName: session.profile?.displayName,
            role: role,
            avatarJPEG: avatar.flatMap(thumbnailJPEG)
        )
    }

    /// A discovery card draws the face at 56pt, so 128px covers a 3× screen
    /// and lands well inside the 24 KB budget. Compressed at a lower quality
    /// than `AvatarStore` uses for the real upload: this copy is thrown away
    /// the moment the household exists and the bucket becomes readable.
    private static func thumbnailJPEG(_ image: UIImage) -> Data? {
        let side: CGFloat = 128
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
            .image { _ in image.draw(in: CGRect(x: 0, y: 0, width: side, height: side)) }
        guard let data = rendered.jpegData(compressionQuality: 0.6),
              data.count <= HouseholdPairingIdentity.maxAvatarBytes else { return nil }
        return data
    }

    private static func peerName(_ name: String) -> String {
        var trimmed = name
        while trimmed.utf8.count > 63 { trimmed = String(trimmed.dropLast()) }
        return trimmed.isEmpty ? "Keepo" : trimmed
    }

    // MARK: - Delegate plumbing

    /// Every delegate callback below arrives on a private queue, so each one
    /// hops here before touching a single property. `@Observable` state
    /// mutated off the main actor is a data race that SwiftUI will read
    /// mid-render.
    func handle(_ data: Data) {
        guard let message = try? JSONDecoder().decode(HouseholdPairingMessage.self, from: data) else { return }

        // The three code messages are the session's own business and are
        // never delivered to the ceremony's inbox — same as `identity`
        // below. `HouseholdSetupCoordinator` neither knows nor needs to know
        // that a code happened. See HouseholdPairingSession+Code.swift.
        if handleCodeMessage(message) { return }

        if case .identity(let remote) = message {
            // Owner side: an identity that arrives before the code has been
            // answered is either a peer skipping the gate or one that failed
            // it. Either way it is not somebody this phone has agreed to
            // know, and dropping it is what keeps the gate from being
            // decorative. The guest has no code to check and accepts the
            // owner's identity on arrival — it only ever sees one after its
            // own `.codeAccepted`.
            if identity.role == .owner && challenge?.isVerified != true { return }
            guard remote.protocolVersion == HouseholdPairingIdentity.protocolVersion else {
                state = .failed("One of you is on an older version of Keepo. Update both phones and try again.")
                stop()
                return
            }
            // Two phones signed into the same account — which is exactly what
            // happens when this is tested on two simulators. Caught here,
            // where it can be explained, rather than four steps later inside
            // `accept_invite` as "cannot accept your own invite".
            guard remote.userId != identity.userId else {
                state = .failed("That phone is signed in to the same Keepo account as this one.")
                stop()
                return
            }
            guard remote.role != identity.role else { return }
            peer = remote
            state = .paired(remote)
            return
        }

        deliver(message)
    }

    func connected(to peerID: MCPeerID) {
        // First peer wins. A second one is left in the session but never
        // spoken to, and drops out on its own timeout.
        guard connectedPeer == nil else { return }
        connectedPeer = peerID
        // A new link starts clean; `step` treats a stale `didPeerStop` as
        // fatal and would abort a ceremony that has not begun.
        didPeerStop = false
        peerStopReason = nil
        // **Nothing is announced here** (audit finding 6): both sides used to
        // send their identity the instant the pipe opened, making a name and
        // a face readable by anything in range. Who they are waits on the code.
        state = .verifying
    }

    func disconnected(from peerID: MCPeerID) {
        guard connectedPeer == peerID else { return }
        connectedPeer = nil
        state = .lost
    }
}
