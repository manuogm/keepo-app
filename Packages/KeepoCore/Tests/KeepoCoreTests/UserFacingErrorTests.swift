import Foundation
import LocalAuthentication
import Supabase
import Testing
@testable import KeepoCore

@Suite("UserFacingError")
struct UserFacingErrorTests {
    @Test("an offline network error gets a short, honest message")
    func offlineError() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(UserFacingError.describe(error) == "You appear to be offline. Please try again once you're back online.")
    }

    @Test("a P0001 PostgrestError (a plain RPC `raise exception`) is shown verbatim")
    func applicationRaisedMessage() {
        let error = PostgrestError(code: "P0001", message: "this category cannot be deleted")
        #expect(UserFacingError.describe(error) == "this category cannot be deleted")
    }

    @Test("a non-P0001 PostgrestError never leaks its raw message to the UI")
    func engineErrorIsSuppressed() {
        let error = PostgrestError(code: "3F000", message: "schema \"net\" does not exist")
        let described = UserFacingError.describe(error)
        #expect(described == "Something went wrong. Please try again.")
        #expect(!described.contains("net"))
    }

    @Test("a PostgrestError with no code at all is treated as an engine error, not application-raised")
    func missingCodeIsSuppressed() {
        let error = PostgrestError(code: nil, message: "relation \"widgets\" does not exist")
        #expect(UserFacingError.describe(error) == "Something went wrong. Please try again.")
    }

    @Test("a plain, unrelated Error type falls back to the generic message")
    func arbitraryErrorIsSuppressed() {
        struct SomeError: Error {}
        #expect(UserFacingError.describe(SomeError()) == "Something went wrong. Please try again.")
    }
}

/// A cancelled load is routine control flow — `.task(id:)` cancels the
/// in-flight work whenever its id changes — and must never surface as a red
/// error under a screen that is about to be correct.
@Suite("Cancellation is not a failure")
struct UserFacingErrorCancellationTests {
    @Test("A cancelled task is recognised as cancellation")
    func cancellationIsRecognised() {
        #expect(UserFacingError.isCancellation(CancellationError()))
    }

    @Test("A real failure is not mistaken for a cancellation")
    func realFailuresAreNotCancellations() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(UserFacingError.isCancellation(offline) == false)

        struct Boom: Error {}
        #expect(UserFacingError.isCancellation(Boom()) == false)
    }

    /// Dismissing the Face ID sheet is an instruction to stop, not a
    /// failure — an alert answering it reads as a bug.
    @Test("Every way of dismissing a biometric prompt counts as cancellation", arguments: [
        LAError.Code.userCancel, .appCancel, .systemCancel
    ])
    func biometricDismissalIsCancellation(code: LAError.Code) {
        #expect(UserFacingError.isCancellation(LAError(code)))
    }

    @Test("A biometric prompt that ran and refused is a failure, not a cancellation")
    func biometricRefusalIsNotCancellation() {
        #expect(UserFacingError.isCancellation(LAError(.authenticationFailed)) == false)
    }
}

/// The generic fallback is actively harmful here: the user is holding a
/// device that just refused them, and "Please try again" invites exactly
/// the thing that will fail again. Every one of these has to name the
/// obstacle and the way past it.
@Suite("Device authentication failures say what to do")
struct UserFacingErrorStepUpTests {
    @Test("No passcode set names the Settings screen that fixes it")
    func noDeviceAuthentication() {
        let described = UserFacingError.describe(StepUpError.noDeviceAuthentication)
        #expect(described.contains("no passcode set"))
        #expect(described.contains("Settings"))
        #expect(described != "Something went wrong. Please try again.")
    }

    @Test("A failed match points at the passcode fallback the policy now has")
    func authenticationFailedOffersPasscode() {
        let described = UserFacingError.describe(LAError(.authenticationFailed))
        #expect(described.contains("Use Passcode"))
    }

    @Test("A policy evaluation that reported failure without an error still says something useful")
    func notAuthenticated() {
        #expect(UserFacingError.describe(StepUpError.notAuthenticated) == "Keepo couldn't confirm it's you. Please try again.")
    }
}

/// `delete-account` is the only Edge Function a user invokes directly, and
/// its bodies ("deletion failed", "invalid session") are written for the
/// function's log, not for a person.
@Suite("Edge Function failures never show operator text")
struct UserFacingErrorEdgeFunctionTests {
    @Test("A 401 tells the user to sign back in, which is what actually fixes it")
    func expiredSession() {
        let error = FunctionsError.httpError(code: 401, data: Data(#"{"error":"invalid session"}"#.utf8))
        let described = UserFacingError.describe(error)
        #expect(described == "Your session has expired. Please sign out, sign back in, and try again.")
        #expect(!described.contains("invalid session"))
    }

    @Test("Any other status gets a plain message, and never the response body")
    func serverRefused() {
        let error = FunctionsError.httpError(code: 500, data: Data(#"{"error":"deletion failed"}"#.utf8))
        let described = UserFacingError.describe(error)
        #expect(described == "The server couldn't finish that request. Please try again in a moment.")
        #expect(!described.contains("deletion failed"))
    }

    /// Deliberately absent from every message above: a 500 from
    /// `delete-account` arrives *after* the rows are gone, so a reassuring
    /// "nothing was changed" would be a lie in the one case it matters.
    @Test("No message claims the request had no effect")
    func neverClaimsNothingChanged() {
        let error = FunctionsError.httpError(code: 500, data: Data())
        let described = UserFacingError.describe(error)
        #expect(!described.lowercased().contains("nothing was changed"))
        #expect(!described.lowercased().contains("no changes"))
    }
}
