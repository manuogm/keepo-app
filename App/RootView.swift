import KeepoCore
import SwiftUI
import UIKit

/// Routes on SessionStore.phase: loading while signing in, OnboardingView
/// until a base currency + first account exist, main TabView after.
struct RootView: View {
    @State private var session = SessionStore()
    @State private var network = NetworkMonitor()
    @State private var needsReviewCount = 0
    /// Set by a tapped capture notification (via `NotificationRouter`) —
    /// see `openPendingCaptureIfNeeded` for why this is re-tried on both
    /// the router firing and `session.phase` changing.
    @State private var router = NotificationRouter.shared
    @State private var deepLinkedCapture: PublicSchema.TransactionsWithDetailsSelect?
    @State private var showDeepLinkedCapture = false
    /// Backs the privacy curtain instead of `@Environment(\.scenePhase)` —
    /// SwiftUI's `scenePhase` is documented (and reproduces on real devices,
    /// never in the simulator) to flicker to `.inactive` for reasons that
    /// have nothing to do with backgrounding — app-launch settling, sheet/
    /// alert presentation transitions — and the curtain has no debounce or
    /// `allowsHitTesting(false)` guard (it can't: it must block real
    /// backgrounding instantly, before the app-switcher snapshot). Every
    /// false-positive flicker silently ate the next tap. `UIApplication`'s
    /// own `willResignActive`/`didBecomeActive` notifications are the
    /// authoritative signal for "about to stop being the active app" (the
    /// same instant the OS takes the switcher snapshot) without that quirk.
    @State private var isSceneActive = true
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppSettingsKeys.appearanceMode) private var appearanceMode = AppearanceMode.system

    var body: some View {
        Group {
            switch session.phase {
            case .loading:
                loadingView
            case .needsSignIn:
                OTPSignInView(session: session)
            case .needsOnboarding:
                OnboardingView(session: session) {
                    Task { try? await session.refreshProfile() }
                }
            case .ready:
                TabView {
                    NavigationStack {
                        HomeView(session: session)
                    }
                    .tabItem { Label("Home", systemImage: "globe") }
                    .badge(needsReviewCount > 0 ? needsReviewCount : 0)

                    NavigationStack {
                        AccountsListView(session: session)
                    }
                    .tabItem { Label("Accounts", systemImage: "creditcard") }

                    NavigationStack {
                        TransactionsListView(session: session)
                    }
                    .tabItem { Label("Transactions", systemImage: "list.bullet") }

                    NavigationStack {
                        ProfileView(session: session)
                    }
                    .tabItem { Label("My Profile", systemImage: "person.circle") }
                }
                .tint(Color.primary)
                .environment(\.isPrivacyMode, session.isPrivacyMode)
                .task(id: session.refresh.token) { await loadNeedsReviewCount() }
                // `.overlay`, not `.safeAreaInset` — iOS 26's floating pill tab
                // bar renders above the safe area it reports, so a view
                // placed relative to that reported inset still lands behind
                // the pill's own visual bounds. Floating our own banner a
                // fixed distance off the true screen bottom sidesteps that
                // mismatch entirely.
                .overlay(alignment: .bottom) {
                    if network.isOffline {
                        OfflineStatusBar(lastSyncedAt: session.syncEngine?.lastSyncedAt)
                            .padding(.horizontal)
                            .padding(.bottom, 60)
                    } else if session.outbox.hasStalePending(threshold: 120)
                        || session.syncEngine?.lastErrorMessage != nil {
                        PendingSyncStatusBar(
                            pendingCount: session.outbox.pendingCount,
                            errorMessage: session.outbox.lastError ?? session.syncEngine?.lastErrorMessage,
                            retry: {
                                await session.outbox.drainAll()
                                await session.syncEngine?.pull()
                                session.refresh.bump()
                            }
                        )
                        .padding(.horizontal)
                        .padding(.bottom, 60)
                    }
                }
            case .failed(let message):
                errorView(message)
            }
        }
        .preferredColorScheme(appearanceMode.colorScheme)
        .task { await session.start() }
        .onOpenURL { url in
            Task { await session.handleMagicLink(url: url) }
        }
        // Isolated onto its own invisible view, not chained inline here —
        // adding these three modifiers directly to this already-long chain
        // pushed the type-checker over its time budget (a real compile
        // failure, not a style preference).
        .background(captureDeepLinkHandler)
        // Dashboard (Phase 8) is the first screen whose whole purpose is a
        // large balance — the OS captures the app-switcher snapshot the
        // instant the scene stops being .active, so the curtain has to cover
        // both .inactive (switcher gesture starting) and .background.
        .overlay {
            if !isSceneActive {
                privacyCurtain
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            isSceneActive = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            isSceneActive = true
        }
        // Drain on foreground, not just at launch — a write made offline
        // should sync the moment connectivity is plausible again, without
        // waiting for the next cold start (Phase 11).
        //
        // `isSceneActive = true` here too, redundant with
        // `didBecomeActiveNotification` above — a notification-tap resume
        // can fire `willResignActive`/`didBecomeActive` out of order (real,
        // reported: the app foregrounded straight into a stuck privacy
        // curtain, notification deep-link never reaching the sheet
        // underneath it). `scenePhase` is SwiftUI's own independent signal,
        // not derived from those two notifications, so it self-heals the
        // stuck case; only ever *clears* the curtain here, never sets it,
        // so it can't reintroduce the flicker-to-.inactive false positive
        // this file's own header comment already explains `scenePhase`
        // has and why the curtain doesn't key off it directly.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                isSceneActive = true
                Task {
                    await session.outbox.drainAll()
                    await session.syncEngine?.pull()
                    session.refresh.bump()
                }
            }
        }
        // L5: connectivity regained is exactly the other "went offline,
        // came back" moment `Outbox.drainAll()` already needed on
        // foreground — the sync engine's pull needs the identical trigger.
        .onChange(of: network.isOffline) { wasOffline, isOffline in
            if wasOffline && !isOffline {
                Task {
                    await session.syncEngine?.pull()
                    session.refresh.bump()
                }
            }
        }
    }

    /// A cold launch from a notification tap sets `router.pendingCaptureId`
    /// before `session.phase` ever reaches `.ready` — retried on both
    /// signals so whichever lands second is the one that actually opens
    /// the sheet.
    private var captureDeepLinkHandler: some View {
        Color.clear
            .sheet(isPresented: $showDeepLinkedCapture) {
                if let deepLinkedCapture {
                    TransactionFormView(session: session, mode: .edit(deepLinkedCapture, sibling: nil)) {
                        session.refresh.bump()
                    }
                }
            }
            .onChange(of: router.pendingCaptureId) { _, _ in Task { await openPendingCaptureIfNeeded() } }
            .onChange(of: session.phase) { _, _ in Task { await openPendingCaptureIfNeeded() } }
    }

    /// Opens the same "review a capture" screen `NeedsReviewView.openForReview`
    /// does — `TransactionFormView` in edit mode, per app-architecture.md,
    /// not a bespoke screen — but reachable directly from a notification tap
    /// instead of a Needs Review list tap. Only fires once `.ready` (needs
    /// `session.profile`/`session.dbQueue`); `pendingCaptureId` is left set
    /// until it resolves, so the retry from `session.phase` changing is what
    /// actually opens it on a cold launch.
    ///
    /// `@MainActor` explicitly — every other screen's identical
    /// read-then-mutate-@State pattern gets this for free from `.task {}`,
    /// whose closure SwiftUI itself types as `@MainActor`. This function is
    /// started from a plain `Task { }` inside `.onChange`'s (non-`@MainActor`)
    /// closure instead, which doesn't carry that guarantee — the `@State`
    /// writes below could resume on whatever thread `session.dbQueue.read`'s
    /// continuation happens to land on, which crashed with "Call must be
    /// made on main thread" (reported: notification tap → app resumes into
    /// a stuck privacy curtain / crash, deep-link never completing).
    @MainActor
    private func openPendingCaptureIfNeeded() async {
        guard
            session.phase == .ready,
            let id = router.pendingCaptureId,
            let ownerId = session.profile?.id,
            let baseCurrency = session.profile?.baseCurrency
        else { return }
        router.pendingCaptureId = nil
        guard let transaction = try? await session.dbQueue.read({ database in
            try LocalTransactionRow.fetchOne(
                database, id: id.uuidString, baseCurrency: baseCurrency, ownerId: ownerId.uuidString
            )
        }) else { return }
        deepLinkedCapture = transaction
        showDeepLinkedCapture = true
    }

    private func loadNeedsReviewCount() async {
        let items = (try? await NeedsReviewRepository.fetchAll(client: session.client)) ?? []
        needsReviewCount = items.filter { $0.kind != "reconciliation_gap" }.count
    }

    private var loadingView: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text("Keepo")
                    .font(.title2).fontWeight(.bold)
                    .foregroundStyle(Color.primary)
            }
        }
    }

    private var privacyCurtain: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            Text("Keepo")
                .font(.title2).fontWeight(.bold)
                .foregroundStyle(Color.primary)
        }
    }

    private func errorView(_ message: String) -> some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            VStack(spacing: 12) {
                Text("Couldn't connect")
                    .font(.title2).fontWeight(.bold)
                    .foregroundStyle(Color.primary)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
    }
}

#Preview {
    RootView()
}
