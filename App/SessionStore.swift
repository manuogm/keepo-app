import Foundation
import KeepoCore
import Observation
import Supabase

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
    private let authProvider: AuthProvider
    private var userId: UUID?

    public init() {
        let config = Self.loadConfig()
        let client = makeSupabaseClient(config: config)
        self.client = client
        // The only place this branches: StubAuthProvider refuses to run
        // against anything but the local stack (see its own precondition),
        // so a build pointed at a hosted SupabaseURL needs the hosted-
        // capable provider instead. Nothing else in the app knows or cares
        // which is active — see AuthProvider.swift.
        self.authProvider = config.isLocal
            ? StubAuthProvider(client: client, config: config)
            : PasswordAuthProvider(client: client)
    }

    public func start() async {
        do {
            let session = try await authProvider.signIn()
            userId = session.user.id
            try await refreshProfile()
        } catch {
            phase = .failed(String(describing: error))
        }
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
        guard
            let urlString = Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String,
            let url = URL(string: urlString),
            let anonKey = Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String,
            !anonKey.isEmpty
        else {
            fatalError(
                "Missing SupabaseURL/SupabaseAnonKey in Info.plist — copy Config/Debug.xcconfig.example "
                    + "to Config/Debug.xcconfig and fill in real values."
            )
        }
        return SupabaseConfig(url: url, anonKey: anonKey)
    }
}
