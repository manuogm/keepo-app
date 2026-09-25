import Foundation
import LocalAuthentication
import Supabase
import os

/// Every screen's error text goes through this, never `String(describing:
/// error)` directly — that dumps an NSError's entire `debugDescription`,
/// including its full nested `userInfo` (found live in Phase 11's offline
/// walkthrough: a plain "could not connect" surfaced as a dozen lines of
/// `_NSURLErrorFailingURLSessionTaskErrorKey`/`_kCFStreamErrorCodeKey`
/// nested-error text).
///
/// Five outcomes, in order: a network-unreachable error gets a short,
/// honest message; a device-authentication refusal names the obstacle and
/// the way past it; one of *our own* deliberately-written RPC messages
/// (see below) is shown verbatim, exactly as intended; an Edge Function
/// that refused gets a message written here rather than the operator text
/// in its response body; anything else — an engine-internal error that was
/// never written with an end user in mind — gets a generic fallback
/// instead of leaking implementation detail. That last case isn't
/// hypothetical: a missing `pg_net` extension once surfaced literally
/// `schema "net" does not exist` in the base-currency change flow, because
/// `PostgrestError.errorDescription` is just the raw Postgres message and
/// the old fallback showed it unfiltered.
///
/// **Every message here has to end somewhere the reader can act.** A
/// sentence that only says something failed leaves them tapping the same
/// button again; the generic fallback is the last resort, not the default.
public enum UserFacingError {
    private static let logger = Logger(subsystem: "app.keepo", category: "UserFacingError")

    public static func describe(_ error: Error) -> String {
        if isOffline(error) {
            return "You appear to be offline. Please try again once you're back online."
        }
        if let authenticationMessage = authenticationMessage(error) {
            return authenticationMessage
        }
        if let applicationMessage = applicationRaisedMessage(error) {
            return applicationMessage
        }
        if let edgeFunctionMessage = edgeFunctionMessage(error) {
            return edgeFunctionMessage
        }
        logger.error("Suppressed from UI, showing a generic message instead: \(String(describing: error))")
        return "Something went wrong. Please try again."
    }

    /// Whether the work was cancelled rather than failed — a `.task(id:)`
    /// whose id changed while a load was in flight, which SwiftUI cancels by
    /// design, or the user dismissing a Face ID / passcode prompt.
    ///
    /// This is routine control flow, not a failure: the id changed because
    /// something the screen depends on changed, and a fresh load is already
    /// running. Surfacing it puts a red error under a screen that is about to
    /// be correct. Home hit this constantly once its task id included the set
    /// of mounted widgets — adding a widget cancels the in-flight read every
    /// single time.
    ///
    /// The biometric cases matter for the same reason from the other end: a
    /// user who taps "Cancel" on the Face ID sheet has *told* the app to
    /// stop, and answering that with an error alert reads as a bug. Only a
    /// refusal they did not choose is worth interrupting them over.
    ///
    /// A sibling of `isOffline` below, and used the same way: callers that
    /// know the difference ask first, rather than this function silently
    /// deciding for every caller (some of which — `SessionStore.phase`,
    /// capture notifications — need a non-optional message).
    public static func isCancellation(_ error: Error) -> Bool {
        if let authenticationError = error as? LAError {
            return [.userCancel, .appCancel, .systemCancel].contains(authenticationError.code)
        }
        return error is CancellationError || (error as NSError).code == NSUserCancelledError
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

    /// Step-up failures are the one class of error where the generic
    /// fallback is actively harmful. The user is holding a device that just
    /// refused them, and "Something went wrong. Please try again." invites
    /// them to do the exact thing that will fail again — while the real
    /// obstacle (no passcode set, a face the sensor won't match) is
    /// something they can fix in under a minute if anyone tells them what it
    /// is.
    ///
    /// Deliberately short: `.deviceOwnerAuthentication` absorbs the cases a
    /// biometrics-only policy used to surface here — no biometry, none
    /// enrolled, locked out after three failures — by falling through to the
    /// passcode. What is left is a device with no passcode at all, and a
    /// passcode entered wrongly.
    private static func authenticationMessage(_ error: Error) -> String? {
        if let stepUpError = error as? StepUpError {
            switch stepUpError {
            case .noDeviceAuthentication:
                return "Keepo couldn't check that it's you, because this iPhone has no passcode set. "
                    + "Add one in Settings › Face ID & Passcode, then try again."
            case .notAuthenticated:
                return "Keepo couldn't confirm it's you. Please try again."
            }
        }
        guard let authenticationError = error as? LAError, authenticationError.code == .authenticationFailed else {
            return nil
        }
        return "That didn't match. Try again, and tap \"Use Passcode\" if Face ID keeps failing."
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

    /// `delete-account` is the only Edge Function the user invokes directly,
    /// and its bodies ("deletion failed", "invalid session") are operator
    /// text written for the function's log, not for a person. The status is
    /// the only part worth reading: 401 means the stored session is no
    /// longer good and signing back in genuinely fixes it, which is a
    /// different instruction from "try again".
    ///
    /// Nothing here claims the request had no effect. A 500 from
    /// `delete-account` comes *after* the rows are gone, and telling
    /// someone their data is untouched when it is not would be worse than
    /// saying nothing.
    private static func edgeFunctionMessage(_ error: Error) -> String? {
        guard let functionsError = error as? FunctionsError else { return nil }
        if case .httpError(let code, _) = functionsError, code == 401 {
            return "Your session has expired. Please sign out, sign back in, and try again."
        }
        return "The server couldn't finish that request. Please try again in a moment."
    }
}

extension UserFacingError {
    /// Whether the server refused a write for a reason that will not change
    /// by sending it again — so retrying it is pointless, and the local
    /// mirror's optimistic copy of it is now a claim the server has rejected.
    ///
    /// The outbox retried every failed write forever, backing off to five
    /// minutes, whatever the failure. For a network blip that is right. For
    /// a refusal it is not: the write never lands, the local write-through
    /// that preceded it stays on screen as if it had, and the only sign
    /// anything is wrong is a pending-sync banner that never clears. Several
    /// transfer bugs were silent for exactly this reason.
    ///
    /// Final: a sentence the database raised on purpose (`P0001`), an
    /// integrity or data error (classes `23` and `22` — a duplicate key on a
    /// *create* never gets here, the senders already treat that as "already
    /// applied"), and an RLS or grant refusal (`42501`). Everything else is
    /// assumed transient, including every PostgREST-level `PGRST…` code —
    /// "function not found" is what an app ahead of an un-pushed migration
    /// sees, and that one does fix itself once the migration lands. So does a
    /// rate limit, which the schema raises as `P0001` and is the one such
    /// sentence that is not final.
    public static func isFinalRefusal(_ error: Error) -> Bool {
        guard let postgrestError = error as? PostgrestError, let code = postgrestError.code else { return false }
        if code == "P0001" { return !postgrestError.message.localizedCaseInsensitiveContains("rate limit") }
        return code.hasPrefix("23") || code.hasPrefix("22") || code == "42501"
    }
}
