import Foundation
import MultipeerConnectivity

/// Asking for the local-network permission at the right moment, which is not
/// the moment the app first needs it.
///
/// Split from `HouseholdPairingSession` for the project's file-length lint,
/// and it reads better here anyway: everything in that file is about two
/// phones talking, and this is about the one thing that has to happen before
/// either of them can.
extension HouseholdPairingSession {
    /// Whether this app run has already raised the local-network prompt.
    /// Answering it is a one-time system decision, so a second priming run
    /// would spend two seconds of radio to ask nothing.
    private static var hasPrimed = false

    /// Raise the local-network permission prompt **now**, on the screen that
    /// explains what the flow is for.
    ///
    /// There is no API that requests this permission: iOS raises the prompt
    /// the first time an app actually uses Bonjour. Left to happen naturally
    /// it lands three screens later, on "Looking for nearby devices" — the
    /// one moment the flow is trying to feel instantaneous, now spent
    /// reading a system alert and wondering whether to trust it. Asking on
    /// the intro costs nothing there and buys a discovery screen that just
    /// works.
    ///
    /// It primes with the **real** `serviceType`, and starts both halves
    /// rather than the one this role will use: the permission is per-app,
    /// and priming with anything else would be asking a different question
    /// from the one the flow later needs answered.
    ///
    /// The advertiser deliberately carries **no** `discoveryInfo`. A real
    /// browser only invites a peer whose info says `role: owner`, so this
    /// two-second appearance cannot be mistaken for somebody offering a
    /// household. Neither object gets a delegate, so nothing it finds is
    /// acted on.
    ///
    /// Nothing is reported back, deliberately: a denial is indistinguishable
    /// from an empty room here exactly as it is on the discovery screen, and
    /// inventing a "permission looks denied" state from a two-second silence
    /// would be a guess shown to the user as a fact. The QR fallback remains
    /// the answer.
    static func primeLocalNetworkPermission() async {
        guard !hasPrimed else { return }
        hasPrimed = true

        let peerID = MCPeerID(displayName: "Keepo")
        let advertiser = MCNearbyServiceAdvertiser(
            peer: peerID, discoveryInfo: nil, serviceType: Self.serviceType
        )
        let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)

        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        // Long enough for the prompt to be raised; short enough that backing
        // straight out of the intro leaves no radio running behind it.
        try? await Task.sleep(for: .seconds(2))
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
    }

}
