import Foundation
import KeepoCore
import Observation
import Supabase
import SwiftData

/// App-level session state: builds the Supabase client from Info.plist
/// (xcconfig-injected), signs in via whichever `AuthProvider` is active, and
/// tracks onboarding completion. Every screen reads state from here rather
/// than talking to Supabase directly — this is the one place auth/session
/// logic lives, per CLAUDE.md's Engineering Principles.
@Observable
@MainActor
public final class SessionStore {
    public enum Phase: Equatable {
        case loading
        case needsOnboarding
        case ready
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    public private(set) var profile: PublicSchema.ProfilesSelect?

    public let client: SupabaseClient
    /// Bumped by every successful write; every list screen's `.task(id:)`
    /// keys off it. See RefreshCoordinator's own doc comment.
    public let refresh = RefreshCoordinator()
    /// Offline write queue + read-through cache (Phase 11). Built once, at
    /// the same point the Supabase client is — both are session-lifetime,
    /// not per-screen.
    public let outbox: Outbox
    public let payloadCache: PayloadCache
    private let authProvider: AuthProvider
    private var userId: UUID?

    public init() {
        let config = Self.loadConfig()
        // `StubAuthProvider`'s local dev flow must never require Face ID
        // enrollment just to run the app — only a non-local (hosted-
        // capable) provider gets the real, biometric-gated Keychain
        // storage. Same `config.isLocal` branch that already chooses the
        // provider itself, mirrored here for storage.
        let client = makeSupabaseClient(config: config, localStorage: config.isLocal ? nil : KeychainSessionStorage())
        self.client = client
        // The only place this branches: StubAuthProvider refuses to run
        // against anything but the local stack (see its own precondition),
        // so a build pointed at a hosted SupabaseURL needs the hosted-
        // capable provider instead. Nothing else in the app knows or cares
        // which is active — see AuthProvider.swift.
        self.authProvider = config.isLocal
            ? StubAuthProvider(client: client, config: config)
            : PasswordAuthProvider(client: client)
        // A container failure here (disk full, corrupt store) would make
        // the entire app unusable either way — no code path exists that
        // doesn't eventually need the outbox once offline writes matter,
        // so this fatalError matches the one in loadConfig() below rather
        // than limping along with an outbox that silently never persists.
        let container: ModelContainer
        do {
            container = try OfflineStore.makeContainer()
        } catch {
            fatalError("Failed to create the offline store: \(error)")
        }
        let context = ModelContext(container)
        self.payloadCache = PayloadCache(context: context)
        self.outbox = Outbox(context: context, sender: LiveTransactionOutboxSender(client: client))
    }

    public func start() async {
        do {
            // The silent, biometric-gated cold-start path first — only
            // falls back to the full interactive signIn() (which may
            // present a SIWA sheet) when there's genuinely no cached
            // session, e.g. first launch or after an explicit sign-out.
            let session: Session
            if let restored = try await authProvider.restoreSession() {
                session = restored
            } else {
                session = try await authProvider.signIn()
            }
            userId = session.user.id
            try await refreshProfile()
            // "Only syncs once a valid session exists" is structural, not a
            // separate check — this line only runs after signIn() above
            // already succeeded.
            await outbox.drainAll()
        } catch {
            phase = .failed(UserFacingError.describe(error))
        }
    }

    /// Forces a fresh biometric check before a high-value action (export,
    /// account deletion, household invite accept/leave) — spec. Never
    /// satisfied by anything cached in memory; see `StepUpAuthenticator`.
    public func stepUp(reason: String) async throws {
        try await authProvider.stepUp(reason: reason)
    }

    public var authCapabilities: AuthProviderCapabilities {
        authProvider.capabilities
    }

    public func refreshProfile() async throws {
        guard let userId else { return }
        let profile = try await ProfileRepository.fetchOwn(client: client, userId: userId)
        self.profile = profile
        phase = profile.onboardedAt == nil ? .needsOnboarding : .ready
    }

    public func completeOnboarding(baseCurrency: String) async throws {
        guard let userId else { return }
        try await ProfileRepository.completeOnboarding(client: client, userId: userId, baseCurrency: baseCurrency)
        try await refreshProfile()
    }

    /// Info.plist keys are set via INFOPLIST_KEY_SupabaseURL/SupabaseAnonKey
    /// in project.yml, themselves populated from the gitignored
    /// Config/*.xcconfig at build time — no secret is ever committed.
    private static func loadConfig() -> SupabaseConfig {
        do {
            return try SupabaseConfig.fromInfoPlist()
        } catch {
            fatalError(
                "Missing SupabaseURL/SupabaseAnonKey in Info.plist — copy Config/Debug.xcconfig.example "
                    + "to Config/Debug.xcconfig and fill in real values."
            )
        }
    }
}
