import Foundation
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
