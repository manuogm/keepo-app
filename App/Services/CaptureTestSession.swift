import Foundation
import KeepoCore
import Observation
import UIKit

/// The onboarding capture test: the cross-process window that makes it
/// safe, the URL that starts it, and the callback that comes back.
///
/// **Why a window exists at all.** The published "Keepo Capture" shortcut
/// carries *"If there's no input: Continue"*, so launching it from Keepo
/// reaches `CaptureIntent` with all three fields empty — which is exactly
/// what a genuinely broken automation looks like too (mis-spelled Wallet
/// keys deliver nothing). Without a guard, a broken setup would report
/// itself as working. So an all-empty invocation is only ever treated as
/// the test while Keepo has said, seconds earlier, that it is expecting
/// one; outside the window it stays what it is — a failure, reported.
///
/// **`UserDefaults` is the channel because the intent may not be in this
/// process.** `CaptureIntent` already reads `AppSettings.notificationLevel`
/// the same way and has done since capture shipped, so this is the proven
/// path rather than a new one — no app group, no extra entitlement, and
/// nothing added to the local schema for a flag that lives for a minute.
enum CaptureTestSession {
    private static let expiryKey = "captureTestExpectingUntil"

    /// Sixty seconds. The round trip itself is a couple of seconds, but the
    /// user may have to confirm an "Open in Shortcuts?" prompt on the way,
    /// and a window that closes while they are reading a system dialog
    /// turns a working setup into a reported failure. Short enough that a
    /// real Apple Pay purchase landing inside it — from an automation whose
    /// keys are *also* mis-mapped — is not a case worth designing for.
    private static let window: TimeInterval = 60

    static func open() {
        UserDefaults.standard.set(Date().addingTimeInterval(window), forKey: expiryKey)
    }

    static func close() {
        UserDefaults.standard.removeObject(forKey: expiryKey)
    }

    /// Read from the intent, which may be running in the Shortcuts host.
    static var isExpectingTest: Bool {
        guard let expiry = UserDefaults.standard.object(forKey: expiryKey) as? Date else { return false }
        return expiry > Date()
    }

    // MARK: - The round trip

    /// Runs the named shortcut and asks Shortcuts to come back to us either
    /// way. The name must match `ShortcutsWalkthrough.shortcutName` exactly
    /// — a shortcut imported a second time lands as "Keepo Capture 1", and
    /// this would then run the older copy, which is one of the failures
    /// `x-error`'s verbatim message is there to explain.
    static var runShortcutURL: URL? {
        var components = URLComponents(string: "shortcuts://x-callback-url/run-shortcut")
        components?.queryItems = [
            URLQueryItem(name: "name", value: ShortcutsWalkthrough.shortcutName),
            URLQueryItem(name: "x-success", value: "\(scheme)://\(Callback.success.rawValue)"),
            URLQueryItem(name: "x-error", value: "\(scheme)://\(Callback.failure.rawValue)")
        ]
        return components?.url
    }

    /// `false` when Shortcuts is not installed — it can be deleted, and a
    /// button that opens nothing is worse than a button that is not there.
    static var canRunShortcuts: Bool {
        guard let url = URL(string: "shortcuts://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    private static let scheme = "com.manuogm.keepo"

    enum Callback: String {
        case success = "capture-test-ok"
        case failure = "capture-test-failed"
    }
}

/// Where the `x-callback-url` answer lands.
///
/// `RootView.onOpenURL` is the only entry point iOS gives us, and the
/// screen that asked is several levels down inside the setup flow — so the
/// result is posted here and observed there, the same shape
/// `SessionStore.linkError` already uses for the magic link's own
/// deep-linked failure.
@Observable
@MainActor
final class CaptureTestCoordinator {
    static let shared = CaptureTestCoordinator()

    /// Set only on `x-error`. **Success is deliberately not recorded**:
    /// `x-success` says the shortcut finished, which is not the same as the
    /// capture arriving — a shortcut can run and write nothing. The pass
    /// condition is the test row appearing in the local mirror, and
    /// nothing else.
    private(set) var shortcutError: String?

    private init() {}

    /// - Returns: whether this URL was one of ours, so `RootView` knows not
    ///   to hand it to the magic-link handler as well.
    func handle(_ url: URL) -> Bool {
        guard let callback = CaptureTestSession.Callback(rawValue: url.host() ?? "") else { return false }
        switch callback {
        case .success:
            shortcutError = nil
        case .failure:
            // Surfaced verbatim, because Shortcuts names the real problem —
            // "the shortcut Keepo Capture was not found", an action that
            // failed — and any paraphrase of ours would be a guess at which
            // of those it was.
            shortcutError = url.queryValue("errorMessage") ?? "Shortcuts could not run “Keepo Capture”."
        }
        return true
    }

    func clear() {
        shortcutError = nil
    }
}

private extension URL {
    func queryValue(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }
}
