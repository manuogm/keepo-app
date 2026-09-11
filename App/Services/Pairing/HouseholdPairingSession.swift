import Foundation
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
        /// Connected, and both identities exchanged. The discovery screen
        /// draws the other person's face from here.
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
            email: session.userEmail,
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
    fileprivate func handle(_ data: Data) {
        guard let message = try? JSONDecoder().decode(HouseholdPairingMessage.self, from: data) else { return }

        if case .identity(let remote) = message {
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

    fileprivate func connected(to peerID: MCPeerID) {
        // First peer wins. A second one is left in the session but never
        // spoken to, and drops out on its own timeout.
        guard connectedPeer == nil else { return }
        connectedPeer = peerID
        // Both sides announce themselves the instant the pipe opens — there
        // is no request/response here, just two phones each saying who they
        // are, which means neither has to wait for the other to ask.
        send(.identity(identity))
    }

    fileprivate func disconnected(from peerID: MCPeerID) {
        guard connectedPeer == peerID else { return }
        connectedPeer = nil
        state = .lost
    }
}

// MARK: - MCSessionDelegate

extension HouseholdPairingSession: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let peer = UncheckedSendable(peerID)
        Task { @MainActor [weak self] in
            switch state {
            case .connected: self?.connected(to: peer.value)
            case .notConnected: self?.disconnected(from: peer.value)
            case .connecting: break
            @unknown default: break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        // `peerID` is deliberately not carried across: this session speaks to
        // exactly one peer, and a message from anyone else could only have
        // come from a connection we never accepted.
        Task { @MainActor [weak self] in self?.handle(data) }
    }

    // The three stream/resource callbacks are required by the protocol and
    // unused: this session sends small JSON messages and nothing else.
    nonisolated func session(
        _ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID
    ) {}

    nonisolated func session(
        _ session: MCSession, didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID, with progress: Progress
    ) {}

    nonisolated func session(
        _ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?
    ) {}
}

// MARK: - Advertising (the owner)

extension HouseholdPairingSession: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        let respond = UncheckedSendable(invitationHandler)
        Task { @MainActor [weak self] in
            guard let self, let session = self.session, self.connectedPeer == nil else {
                respond.value(false, nil)
                return
            }
            // Accepted without asking. The user has already said yes twice —
            // once by starting this flow, once by standing next to the other
            // phone — and a system-styled "Accept?" alert on top of a screen
            // that says "Looking for nearby devices" would be the app asking
            // a question it already knows the answer to. Who was actually
            // found is confirmed on the discovery card, with a face and a
            // name, before anything is created.
            respond.value(true, session)
        }
    }

    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.state = .failed(HouseholdPairingSession.radioFailureMessage)
        }
    }
}

// MARK: - Browsing (the guest)

extension HouseholdPairingSession: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?
    ) {
        let found = UncheckedSendable((browser: browser, peerID: peerID))
        Task { @MainActor [weak self] in
            guard let self, let session = self.session, self.connectedPeer == nil else { return }
            // Only a phone that says it is offering a household. Every other
            // Keepo user in Bonjour range is somebody else's business.
            guard info?["role"] == HouseholdPairingIdentity.Role.owner.rawValue else { return }
            found.value.browser.invitePeer(
                found.value.peerID, to: session, withContext: nil, timeout: 30
            )
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let peer = UncheckedSendable(peerID)
        Task { @MainActor [weak self] in self?.disconnected(from: peer.value) }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor [weak self] in
            self?.state = .failed(HouseholdPairingSession.radioFailureMessage)
        }
    }
}

private extension HouseholdPairingSession {
    /// The same sentence for both radios failing to start, because the user's
    /// fix is the same either way and the underlying `NSError` names a
    /// framework they have never heard of.
    static let radioFailureMessage =
        "Keepo could not start looking for nearby devices. Check that Bluetooth and Wi-Fi are on, "
        + "and that Keepo is allowed to find devices on your local network in Settings."
}
