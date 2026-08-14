import Foundation
import GRDB
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
        case needsSignIn      // no cached session; show the OTP sign-in UI
        case needsOnboarding
        case ready
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    public private(set) var profile: PublicSchema.ProfilesSelect?
    /// Set when a magic-link deep link arrives but `session(from:)` fails
    /// (expired or malformed link). Observed by `OTPSignInView`.
    public private(set) var linkError: String?
    /// Email address of the currently signed-in user, populated at session
    /// start / magic-link completion. Displayed in ProfileView.
    public private(set) var userEmail: String?
    /// Whether the user has toggled financial data out of view (privacy mode).
    /// Injected into the view hierarchy via the `isPrivacyMode` environment key.
    public var isPrivacyMode: Bool = false
    /// The net-worth scope all financial screens compute totals for.
    /// Lifted from HomeView so the PrivacyToggleButton's long-press scope
    /// selector works across tabs without prop drilling.
    public var scope: PublicSchema.AccountScope = .total

    public let client: SupabaseClient
    /// Bumped by every successful write; every list screen's `.task(id:)`
    /// keys off it. See RefreshCoordinator's own doc comment.
    public let refresh = RefreshCoordinator()
    /// Offline write queue + read-through cache (Phase 11). Built once, at
    /// the same point the Supabase client is — both are session-lifetime,
    /// not per-screen.
    public let outbox: Outbox
    /// The pull side of Phase L5's sync engine — `nil` until `userId` is
    /// known (a cursor is meaningless without knowing whose domain it
    /// belongs to), rebuilt on every sign-in rather than constructed once
    /// in `init()` alongside `outbox`, which needs no identity to be usable.
    public private(set) var syncEngine: SyncEngine?
    /// The same GRDB queue `syncEngine` pulls into — Phase L6's read path
    /// queries this directly instead of PostgREST, so it needs to be as
    /// reachable from any screen as `outbox` already is.
    public let dbQueue: DatabaseQueue
    private let authProvider: AuthProvider
    private var userId: UUID?
    /// True when pointed at the local dev stack — controls whether startup
    /// auto-signs in via StubAuthProvider or waits for the OTP UI.
    private let isLocal: Bool

    public init() {
        let config = Self.loadConfig()
        self.isLocal = config.isLocal
        // Only a non-local (hosted-capable) provider gets the stronger,
        // non-default-accessibility Keychain storage — the local dev stub
        // keeps the SDK's own plain storage. Same `config.isLocal` branch
        // that already chooses the provider itself, mirrored here for
        // storage. Never biometric-gated (see `KeychainSessionStorage`'s
        // own header comment for why that broke real-device use entirely).
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
        let dbQueue: DatabaseQueue
        do {
            container = try OfflineStore.makeContainer()
            dbQueue = try LocalStore.makeQueue()
        } catch {
            fatalError("Failed to create the offline store: \(error)")
        }
        self.dbQueue = dbQueue
        let context = ModelContext(container)
        OutboxMigration.migrateIfNeeded(swiftDataContext: context, to: dbQueue)
        self.outbox = Outbox(dbQueue: dbQueue, sender: LiveOutboxSender(client: client))
    }

    /// Rebuilds `syncEngine` for the now-known `userId` — called from every
    /// place `userId` itself gets set, immediately before that same call
    /// site's existing `outbox.drainAll()`, so push and pull start from the
    /// same trigger.
    private func makeSyncEngine(userId: UUID) -> SyncEngine {
        SyncEngine(dbQueue: dbQueue, puller: LiveSyncPuller(client: client), userId: userId.uuidString)
    }

    public func start() async {
        do {
            if let restored = try await authProvider.restoreSession() {
                userId = restored.user.id
                userEmail = restored.user.email
                syncEngine = makeSyncEngine(userId: restored.user.id)
                try await startWithLocalFirstProfile()
            } else if isLocal {
                // Local dev stack: auto-sign in via StubAuthProvider's fixed
                // credentials — no UI needed, no email confirmation required.
                let session = try await authProvider.signIn()
                userId = session.user.id
                userEmail = session.user.email
                syncEngine = makeSyncEngine(userId: session.user.id)
                try await startWithLocalFirstProfile()
            } else {
                // Hosted: no cached session — present the OTP sign-in UI.
                // The signIn() path on PasswordAuthProvider fails against
                // hosted Supabase (email confirmation required by default).
                phase = .needsSignIn
            }
        } catch {
            phase = .failed(UserFacingError.describe(error))
        }
    }

    /// D: a returning user's cold start used to gate `.ready` on a network
    /// `refreshProfile()` call, even though `profiles` is already in the
    /// local mirror from the previous session — every launch paid a full
    /// round-trip just to show the same landing screen it showed last time.
    /// If a local profile row already exists, render from it immediately and
    /// let the outbox drain + sync pull run in the background, re-syncing
    /// `profile`/`phase` only if the pull actually changed something (e.g.
    /// onboarding completed on another device). A genuinely first-ever
    /// login — no local row yet, nothing to render — falls back to the old
    /// synchronous path; `.loading`'s spinner is exactly the right UI for
    /// that one real wait, so no separate first-sync screen is needed.
    private func startWithLocalFirstProfile() async throws {
        guard let userId else { return }
        if let localProfile = try? await dbQueue.read({ database in
            try LocalTableQueries.profile(database, id: userId.uuidString)
        }) {
            profile = localProfile
            phase = localProfile.onboardedAt == nil ? .needsOnboarding : .ready
            Task {
                await outbox.drainAll()
                await syncEngine?.pull()
                if let refreshed = try? await dbQueue.read({ database in
                    try LocalTableQueries.profile(database, id: userId.uuidString)
                }), refreshed != profile {
                    profile = refreshed
                    phase = refreshed.onboardedAt == nil ? .needsOnboarding : .ready
                }
                // The pull can bring in accounts/transactions/balances that
                // existed on the server before this device's first local
                // row, even when the profile row itself is unchanged — every
                // screen keys its load off this token, not off `profile`.
                refresh.bump()
            }
        } else {
            // First-ever login on this device: nothing local to render yet,
            // so this is the one case genuinely worth waiting on.
            try await refreshProfile()
            await outbox.drainAll()
            await syncEngine?.pull()
        }
    }

    /// Sends a magic-link email to `email`. The link opens the app via the
    /// `com.manuogm.keepo://` URL scheme; `handleMagicLink(url:)` completes
    /// the session from there. Also requires `com.manuogm.keepo://auth-callback`
    /// to be listed in the Supabase dashboard under Authentication → URL Configuration.
    public func sendOTP(email: String) async throws {
        try await client.auth.signInWithOTP(
            email: email,
            redirectTo: URL(string: "com.manuogm.keepo://auth-callback"),
            shouldCreateUser: true
        )
    }

    /// Called by `RootView.onOpenURL` when the magic link opens the app.
    /// Extracts the session from the URL and advances the phase.
    public func handleMagicLink(url: URL) async {
        do {
            let session = try await client.auth.session(from: url)
            linkError = nil
            userId = session.user.id
            userEmail = session.user.email
            syncEngine = makeSyncEngine(userId: session.user.id)
            try await refreshProfile()
            await outbox.drainAll()
            await syncEngine?.pull()
        } catch {
            linkError = UserFacingError.describe(error)
        }
    }

    public func signOut() async throws {
        try await client.auth.signOut()
        userId = nil
        userEmail = nil
        profile = nil
        syncEngine = nil
        phase = .needsSignIn
    }

    /// Deletes all of the user's data server-side and signs out locally.
    /// Requires a step-up auth challenge before being called.
    public func deleteAccount() async throws {
        guard let userId else { return }
        try await client.rpc("delete_own_account", params: ["p_user": userId.uuidString]).execute()
        try await signOut()
    }

    /// Forces a fresh biometric check before a high-value action (export,
    /// account deletion, household invite accept/leave) — spec. Never
    /// satisfied by anything cached in memory; see `StepUpAuthenticator`.
    ///
    /// The one choke point every one of those call sites already goes
    /// through — disabling the "Enable Face ID" setting short-circuits
    /// here, so it genuinely means Face ID is never invoked anywhere, not
    /// just skipped at whichever call site happened to be touched.
    public func stepUp(reason: String) async throws {
        guard AppSettings.isFaceIDEnabled else { return }
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
