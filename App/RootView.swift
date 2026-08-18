import KeepoCore
import SwiftUI
import UIKit

/// Routes on SessionStore.phase: loading while signing in, OnboardingView
/// until a base currency + first account exist, main TabView after.
struct RootView: View {
    @State private var session = SessionStore()
    @State private var network = NetworkMonitor()
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
    @State private var captureObserver: DarwinNotificationObserver?
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppSettingsKeys.appearanceMode) private var appearanceMode = AppearanceMode.system

    var body: some View {
        Group {
            switch session.phase {
            case .loading:
                RootLoadingView()
            case .needsSignIn:
                OTPSignInView(session: session)
            case .needsOnboarding:
                OnboardingView(session: session) {
                    Task { try? await session.refreshProfile() }
                }
            case .ready:
                MainTabView(session: session, network: network)
            case .failed(let message):
                RootErrorView(message: message)
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
        .background(CaptureDeepLinkHandler(session: session))
        // C-09: a capture landing while this RootView is already running
        // (the intent fired from a separate host process) otherwise has no
        // way to reach it — same `syncNow()` every other trigger site uses.
        .onAppear {
            guard captureObserver == nil else { return }
            captureObserver = DarwinNotificationObserver(name: CaptureNotify.name) {
                Task { await session.syncNow() }
            }
        }
        // Dashboard (Phase 8) is the first screen whose whole purpose is a
        // large balance — the OS captures the app-switcher snapshot the
        // instant the scene stops being .active, so the curtain has to cover
        // both .inactive (switcher gesture starting) and .background.
        .overlay {
            if !isSceneActive {
                RootPrivacyCurtainView()
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
                Task { await session.syncNow() }
            }
        }
        // L5: connectivity regained is exactly the other "went offline,
        // came back" moment `Outbox.drainAll()` already needed on
        // foreground — the sync engine's pull needs the identical trigger.
        // `syncNow()` drains first — found chasing a real bug: this used to
        // call only `syncEngine?.pull()`, so a write made offline sat
        // queued while the pull's stale server row silently overwrote the
        // optimistic local one on screen the moment connectivity returned.
        .onChange(of: network.isOffline) { wasOffline, isOffline in
            if wasOffline && !isOffline {
                Task { await session.syncNow() }
            }
        }
    }
}

#Preview {
    RootView()
}
