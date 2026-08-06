import Foundation

/// Every screen's error text goes through this, never `String(describing:
/// error)` directly — that dumps an NSError's entire `debugDescription`,
/// including its full nested `userInfo` (found live in Phase 11's offline
/// walkthrough: a plain "could not connect" surfaced as a dozen lines of
/// `_NSURLErrorFailingURLSessionTaskErrorKey`/`_kCFStreamErrorCodeKey`
/// nested-error text). A network-unreachable error gets a short, honest
/// message instead; anything else falls back to `localizedDescription`
/// (for `PostgrestError`, this is already just its own `message` field —
/// still far shorter than the full struct dump).
public enum UserFacingError {
    public static func describe(_ error: Error) -> String {
        isOffline(error)
            ? "You appear to be offline. Please try again once you're back online."
            : error.localizedDescription
    }

    private static func isOffline(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
            NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed
        ].contains(nsError.code)
    }
}
