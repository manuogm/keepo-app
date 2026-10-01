import Foundation
import MultipeerConnectivity

// The three `MultipeerConnectivity` delegate conformances, split from
// HouseholdPairingSession.swift for file length.
//
// Every callback here arrives on a private queue, so each one hops to the
// main actor before touching a single property — `@Observable` state
// mutated off the main actor is a data race SwiftUI will read mid-render.
// The methods they hop into are `internal` rather than `fileprivate` only
// because of this split; nothing outside this pair of files calls them.

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
            guard let session = self?.sessionForIncomingInvitation() else {
                respond.value(false, nil)
                return
            }
            respond.value(true, session)
        }
    }

    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error
    ) {
        Task { @MainActor [weak self] in self?.radioFailed() }
    }
}

// MARK: - Browsing (the guest)

extension HouseholdPairingSession: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?
    ) {
        let found = UncheckedSendable((browser: browser, peerID: peerID))
        // Only a phone that says it is offering a household. Every other
        // Keepo user in Bonjour range is somebody else's business.
        guard info?["role"] == HouseholdPairingIdentity.Role.owner.rawValue else { return }
        Task { @MainActor [weak self] in
            guard let session = self?.sessionForOutgoingInvitation() else { return }
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
        Task { @MainActor [weak self] in self?.radioFailed() }
    }
}
