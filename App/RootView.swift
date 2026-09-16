import KeepoCore
import SwiftUI
import UIKit

/// Routes on SessionStore.phase: loading while signing in, the intro and
/// sign-in before there is a session, `SetupFlowView` until a base
/// currency exists, main TabView after.
struct RootView: View {
    @State private var session = SessionStore()
    /// `let`, not `@State`: `NetworkMonitor` is a process-wide singleton, so
    /// there is no lifetime for `@State` to own — and `@Observable` tracking
    /// works from any stored property a body reads, not only from `@State`.
    private let network = NetworkMonitor.shared
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
    /// Live system appearance, read here because this is the one place in
    /// the app guaranteed not to be inside a modal presentation. A `.sheet`'s
    /// content runs in its own `UIHostingController`, which does not reliably
    /// re-observe a bare system Dark Mode flip while idle on screen — it
    /// only catches up on its next state-driven re-render (a push, a pop,
    /// being dismissed and re-presented), which is exactly the "close and
    /// reopen Profile" symptom this was reported as. Resolving the concrete
    /// scheme up here, where SwiftUI *does* re-render on the flip, and
    /// threading it down to `MainTabView` lets the Profile sheet reassert
    /// `.preferredColorScheme` with a value that actually changes, instead
    /// of leaving it to inherit an environment its own hosting controller
    /// isn't watching.
    @Environment(\.colorScheme) private var systemColorScheme

    private var resolvedColorScheme: ColorScheme {
        appearanceMode.colorScheme ?? systemColorScheme
    }

    /// iOS greys every tinted view in a window while a modal is presented
    /// (`tintAdjustmentMode` flips to `.dimmed`) and is supposed to undo it
    /// on dismissal. That restore never reaches the tab bar, which stays
    /// grey until switching tabs forces it to re-render.
    ///
    /// Confirmed app-wide in device testing, not specific to any one
    /// screen: opening a transaction straight from the Transactions list
    /// and deleting it leaves the tab bar grey exactly the same way, with
    /// no notification involved. So this predates capture quick actions
    /// rather than being caused by them.
    ///
    /// Opting the window out of automatic dimming *removes the state that
    /// was failing to be restored*, instead of trying to catch every
    /// dismissal in the app after the fact and undo it — there is no
    /// dismissal event to reliably hook, and one missed sheet would bring
    /// the bug straight back. Nothing here wants the dimming anyway: every
    /// modal in Keepo is a sheet that already covers what it would dim.
    @MainActor
    private func disableAutomaticTintDimming() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.tintAdjustmentMode = .normal
            }
        }
    }

    @AppStorage(AppSettingsKeys.hasSeenIntro) private var hasSeenIntro = false

    var body: some View {
        Group {
            switch session.phase {
            case .loading:
                RootLoadingView()
            case .needsSignIn:
                // The intro sits in front of sign-in on a device that has
                // not seen it, and never again after that — see
                // `IntroFlowView` for why the flag is device-local and why
                // it is set on reaching sign-in rather than on completing
                // it.
                if hasSeenIntro {
                    OTPSignInView(session: session)
                } else {
                    IntroFlowView(session: session)
                }
            case .needsOnboarding:
                // No completion closure: the setup flow refreshes the
                // profile itself, at the very end of its own commit, and
                // that refresh is what removes this branch from under it.
                SetupFlowView(session: session)
            case .ready:
                MainTabView(session: session, network: network, colorScheme: resolvedColorScheme)
            case .failed(let message):
                RootErrorView(message: message)
            }
        }
        .preferredColorScheme(appearanceMode.colorScheme)
        .task { await session.start() }
        .onOpenURL { url in
            // Capture setup's `x-callback-url` answer comes back on the
            // same scheme as the magic link, and `handleMagicLink` would
            // read it as a malformed one and surface a sign-in error over
            // a signed-in app. Claimed first, then.
            guard !CaptureTestCoordinator.shared.handle(url) else { return }
            Task { await session.handleMagicLink(url: url) }
        }
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
        // Raising the curtain is `willResignActive`'s job alone and must
        // stay eager — it fires while `applicationState` is still `.active`,
        // precisely so the overlay is up BEFORE the OS takes its
        // app-switcher snapshot. Anything that second-guesses it against
        // `applicationState` would leave the balance visible in the switcher,
        // which is the whole reason this exists.
        //
        // *Lowering* it is what has to be redundant. A quick action without
        // `.foreground` (Confirm, a category/account pick, Delete) wakes
        // THIS process in the background — new behavior: `CaptureIntent`
        // runs in a separate host process, so before quick actions existed
        // `RootView` never came up in a background app at all. On that path
        // the curtain goes up correctly (invisibly), and a single missed
        // "we're back" transition then strands it at `false` forever — a
        // full-screen overlay swallowing every touch on a perfectly live
        // app, which is exactly how it was reported from device testing:
        // frozen on the "Keepo" screen, nothing tappable.
        //
        // So three independent signals lower it, and it only takes one:
        // `.onAppear` reads the authoritative state on insertion,
        // `willEnterForeground` fires on every background→foreground
        // transition (the path that broke), and `didBecomeActive` covers
        // returning from merely `.inactive` without ever backgrounding.
        // `scenePhase == .active` below is a fourth, from SwiftUI's own
        // independent signal.
        .onAppear {
            isSceneActive = UIApplication.shared.applicationState == .active
            disableAutomaticTintDimming()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            isSceneActive = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            isSceneActive = true
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
