import Foundation
import Supabase
import os

/// Every screen's error text goes through this, never `String(describing:
/// error)` directly — that dumps an NSError's entire `debugDescription`,
/// including its full nested `userInfo` (found live in Phase 11's offline
/// walkthrough: a plain "could not connect" surfaced as a dozen lines of
/// `_NSURLErrorFailingURLSessionTaskErrorKey`/`_kCFStreamErrorCodeKey`
/// nested-error text).
///
/// Three outcomes, in order: a network-unreachable error gets a short,
/// honest message; one of *our own* deliberately-written RPC messages
/// (see below) is shown verbatim, exactly as intended; anything else — an
/// engine-internal error that was never written with an end user in mind —
/// gets a generic fallback instead of leaking implementation detail. That
/// last case isn't hypothetical: a missing `pg_net` extension once
/// surfaced literally `schema "net" does not exist` in the base-currency
/// change flow, because `PostgrestError.errorDescription` is just the raw
/// Postgres message and the old fallback showed it unfiltered.
public enum UserFacingError {
    private static let logger = Logger(subsystem: "app.keepo", category: "UserFacingError")

    public static func describe(_ error: Error) -> String {
        if isOffline(error) {
            return "You appear to be offline. Please try again once you're back online."
        }
        if let applicationMessage = applicationRaisedMessage(error) {
            return applicationMessage
        }
        logger.error("Suppressed from UI, showing a generic message instead: \(String(describing: error))")
        return "Something went wrong. Please try again."
    }

    /// Whether the work was cancelled rather than failed — a `.task(id:)`
    /// whose id changed while a load was in flight, which SwiftUI cancels by
    /// design.
    ///
    /// This is routine control flow, not a failure: the id changed because
    /// something the screen depends on changed, and a fresh load is already
    /// running. Surfacing it puts a red error under a screen that is about to
    /// be correct. Home hit this constantly once its task id included the set
    /// of mounted widgets — adding a widget cancels the in-flight read every
    /// single time.
    ///
    /// A sibling of `isOffline` below, and used the same way: callers that
    /// know the difference ask first, rather than this function silently
    /// deciding for every caller (some of which — `SessionStore.phase`,
    /// capture notifications — need a non-optional message).
    public static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as NSError).code == NSUserCancelledError
    }

    /// Exposed so callers with their own offline affordance (a persistent
    /// status indicator, a cache fallback already on screen) can skip
    /// showing `describe`'s offline sentence as an alarming, one-off red
    /// error — being offline is ambient state, not a per-action failure.
    public static func isOffline(_ error: Error) -> Bool {
        isOfflineNetworkError(error)
    }

    private static func isOfflineNetworkError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
            NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed
        ].contains(nsError.code)
    }

    /// `P0001` is Postgres's default SQLSTATE for a plain `raise exception
    /// '...'` with no explicit ERRCODE — exactly how every RPC in this
    /// codebase raises a message actually meant for the end user (e.g.
    /// `delete_category_and_reassign`'s "this category cannot be
    /// deleted", `create_household`'s "you already belong to a
    /// household"). Any other code — an undefined schema/table/column, a
    /// permission error, a raw constraint violation, ... — is an error
    /// that escaped from somewhere never written with a user-facing
    /// message in mind, and showing its text verbatim only leaks
    /// implementation detail.
    private static func applicationRaisedMessage(_ error: Error) -> String? {
        guard let postgrestError = error as? PostgrestError, postgrestError.code == "P0001" else { return nil }
        return postgrestError.message
    }
}
