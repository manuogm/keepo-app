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

    /// Establishes a session, signing up on first use if needed. May
    /// present interactive UI (a SIWA sheet); `restoreSession()` below is
    /// the silent alternative for a cold start with an already-cached
    /// session.
    @discardableResult
    func signIn() async throws -> Session

    func signOut() async throws

    /// The biometric-gated cold-start path — reads whatever cached session
    /// already exists without any interactive sign-in flow, `nil` if there
    /// isn't one. Distinct from `signIn()`, which may sign up on first use;
    /// this never creates anything, only reads. `SessionStore.start()`
    /// tries this first, falling back to `signIn()` only when it's `nil`.
    func restoreSession() async throws -> Session?

    /// Forces a fresh biometric check before a high-value action (export,
    /// account deletion, household invite accept/leave — spec) — never
    /// satisfied by whatever's merely cached in memory.
    func stepUp(reason: String) async throws

    /// So Settings can show "Sign in with Apple" (or gate a step-up
    /// prompt's copy) only when the active provider actually supports it,
    /// instead of the UI knowing which provider is live.
    var capabilities: AuthProviderCapabilities { get }
}

public struct AuthProviderCapabilities: Sendable, Equatable {
    public let supportsAppleSignIn: Bool
    public let requiresBiometricStepUp: Bool

    public init(supportsAppleSignIn: Bool, requiresBiometricStepUp: Bool) {
        self.supportsAppleSignIn = supportsAppleSignIn
        self.requiresBiometricStepUp = requiresBiometricStepUp
    }
}
