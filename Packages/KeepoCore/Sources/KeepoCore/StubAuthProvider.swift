import Foundation
import Supabase

/// Development-only auth: signs into a fixed local dev account instead of
/// real Sign in with Apple, so the rest of the app — and RLS — can be
/// exercised against a genuine Supabase session without a paid Apple
/// Developer account. The password is fixed and non-secret on purpose; it is
/// only ever valid against a local `supabase start` stack.
///
/// Refuses to run against anything but a local Supabase URL (see `init`) —
/// this must never be what ships, and the check makes that a crash instead
/// of a silent misconfiguration.
public final class StubAuthProvider: AuthProvider {
    private let client: SupabaseClient
    private let email = "dev@keepo.local"
    private let password = "keepo-dev-stub-password"

    public init(client: SupabaseClient, config: SupabaseConfig) {
        precondition(
            config.isLocal,
            "StubAuthProvider must never run against a non-local Supabase URL — "
                + "swap in AppleAuthProvider for hosted use."
        )
        self.client = client
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
