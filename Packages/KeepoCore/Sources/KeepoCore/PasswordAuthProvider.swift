import Foundation
import Supabase

/// Hosted-capable auth: same fixed-credentials shape as `StubAuthProvider`,
/// but with no `isLocal` precondition — this is what proves the app can
/// actually authenticate against a hosted Supabase project at all, rather
/// than exclusively exercising `StubAuthProvider`'s local-only path (see
/// keepo-v1-master-plan.md, Phase 5: "the app has never once authenticated
/// against the linked hosted project").
///
/// Still not real Sign in with Apple — the password is fixed and
/// non-secret, same as the stub. `AppleAuthProvider` (Phase 20) replaces
/// this once the paid Apple Developer account exists; nothing outside the
/// `AuthProvider` protocol depends on which is active.
public final class PasswordAuthProvider: AuthProvider {
    private let client: SupabaseClient
    private let email: String
    private let password = "keepo-hosted-proof-password"

    /// `email` defaults to a fixed hosted-proof identity, distinct from
    /// `StubAuthProvider`'s `dev@keepo.local` — the two never run against
    /// the same project (the stub refuses non-local), but keeping the
    /// identities visibly different avoids any confusion when reading logs
    /// or the Supabase dashboard's user list. `.dev`, not `.test` — hosted
    /// GoTrue's email validator rejects `.test` as an invalid address
    /// (confirmed empirically; the local stack is more permissive).
    public init(client: SupabaseClient, email: String = "hosted-proof@keepo.dev") {
        self.client = client
        self.email = email
    }

    public func currentSession() async throws -> Session? {
        try? await client.auth.session
    }

    @discardableResult
    public func signIn() async throws -> Session {
        if let session = try? await client.auth.session {
            return session
        }
        do {
            let response = try await client.auth.signUp(email: email, password: password)
            if let session = response.session {
                return session
            }
        } catch {
            // Already registered from a previous run — fall through to sign in.
        }
        return try await client.auth.signIn(email: email, password: password)
    }

    public func signOut() async throws {
        try await client.auth.signOut()
    }
}
