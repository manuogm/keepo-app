import Foundation

/// A one-way hop for a framework value that predates Swift concurrency.
///
/// `MCPeerID`, `MCSession`, `MCNearbyServiceBrowser` and
/// `AVCaptureSession` are all classes Apple has not marked `Sendable`, and
/// all four are handed to us on a framework-owned queue with the expectation
/// that we hand them straight back. Under Swift 6's strict checking, moving
/// one onto the main actor is a hard error — correctly, in general, because
/// the compiler cannot know whether we are about to mutate it from two
/// places.
///
/// This box is the place that claim gets made explicitly, once, with the
/// reasoning attached, instead of `@unchecked Sendable` being sprinkled over
/// four delegate signatures where nobody would read it.
///
/// **What makes each use safe.** Every value put in here is either only
/// compared and passed back to the framework (`MCPeerID`), or only ever
/// touched from one place after the hop (`MCSession` is created and read on
/// the main actor; `AVCaptureSession` is started and stopped off it and
/// nowhere else). None of them is mutated from two queues, which is the race
/// the checker exists to prevent.
///
/// Do **not** reach for this to silence a warning about a type of our own.
/// Ours can be made properly `Sendable`; these cannot.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
