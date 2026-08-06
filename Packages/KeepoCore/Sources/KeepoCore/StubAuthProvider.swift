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
    private let email: String
    private let password = "keepo-dev-stub-password"

    public init(client: SupabaseClient, config: SupabaseConfig) {
        precondition(
            config.isLocal,
            "StubAuthProvider must never run against a non-local Supabase URL — "
                + "swap in AppleAuthProvider for hosted use."
        )
        self.client = client
        self.email = Self.resolveEmail()
    }

    /// Debug-only second identity, so households (Phase 7) and anything
    /// after it can be exercised manually with two real, distinct users —
    /// this provider previously hardcoded one fixed email, meaning the app
    /// itself could never have a second user. `KEEPO_DEV_USER=b` as an
    /// environment variable (Xcode scheme → Run → Arguments) selects it;
    /// anything else, including unset, keeps the original identity so no
    /// existing session/behavior changes by default.
    private static func resolveEmail() -> String {
        switch ProcessInfo.processInfo.environment["KEEPO_DEV_USER"] {
        case "b": return "dev-b@keepo.local"
        default: return "dev@keepo.local"
        }
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
