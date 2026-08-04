import Foundation
import Supabase

/// The seam between "how the app authenticates" and everything else. Two
/// implementations: `StubAuthProvider` now (no paid Apple Developer account
/// yet), `AppleAuthProvider` (real Sign in with Apple) once one exists.
/// Nothing outside this protocol depends on which is active.
public protocol AuthProvider: Sendable {
    /// The current session, or `nil` if not signed in. "Not signed in" is a
    /// normal state, not an error — only genuine failures throw.
    func currentSession() async throws -> Session?

    /// Establishes a session, signing up on first use if needed.
    @discardableResult
    func signIn() async throws -> Session

    func signOut() async throws
}
