import Foundation

/// How to wire a Wallet automation to Keepo, as data.
///
/// **One copy of these instructions exists in the app.** Onboarding's
/// capture step and Profile → My Automations' `WalletAutomationGuideView`
/// both render from here, because two copies of a six-step procedure drift
/// the first time iOS moves a button — and then one screen is quietly
/// wrong.
///
/// **The text is the durable half, not the video.** Every step ships with
/// its written instruction visible beside its clip, and the whole
/// walkthrough must be completable from the text alone: a video-only
/// procedure excludes VoiceOver users and anyone running Reduce Motion, and
/// Shortcuts' UI will move again long before these words stop being true.
/// A clip is therefore `nil`-able and the view degrades to text — which is
/// also what lets the flow ship before the clips are recorded.
public enum ShortcutsWalkthrough {
    /// The name the automation runs, and the name the test round-trip asks
    /// Shortcuts for. **It must match the shortcut behind `installURL`
    /// exactly** — a renamed shortcut is the single most likely reason the
    /// test fails, which is why `x-error`'s message is surfaced verbatim.
    public static let shortcutName = "Keepo Capture"

    /// What Keepo's action is called inside Shortcuts — `CaptureIntent`'s
    /// own title, repeated here so the manual fallback can name it. The
    /// two must stay in step; the fallback tells a user to go and find this
    /// exact row in the action list.
    public static let actionName = "Log Apple Pay Purchase"

    /// Where the prebuilt shortcut is published, **as published today**.
    ///
    /// An iCloud share link dies if it is ever revoked or re-shared, which
    /// made this the one piece of onboarding that could break with no code
    /// changing — and re-pointing it meant an App Store release. It is now
    /// the *fallback*: `installURL(functionsBaseURL:)` prefers the
    /// `capture-shortcut` Edge Function, whose 302 can be re-pointed with a
    /// `supabase secrets set`.
    ///
    /// Kept, rather than deleted, because the redirect is one more thing
    /// that can be down — and a link that works offline-of-Supabase is
    /// strictly better than no link. The import step still needs its text
    /// fallback behind both.
    public static let installURLString =
        "https://www.icloud.com/shortcuts/67d23227435a43a4926d9b22d1bb5065"

    /// The direct link, with no redirect in front of it.
    public static var installURL: URL? { URL(string: installURLString) }

    /// Where the walkthrough's install button actually points.
    ///
    /// - Parameter functionsBaseURL: the project's Supabase URL, from
    ///   `SupabaseConfig`. Passed in rather than read here because
    ///   `KeepoCore` has no business reading the app's Info.plist, and
    ///   because it is `nil` in exactly the case that matters — a build
    ///   with no configuration at all, which should still show a working
    ///   button.
    ///
    /// Prefers the redirect so a dead share link is a secret change rather
    /// than a release; falls back to the literal above when there is no
    /// project to redirect through.
    public static func installURL(functionsBaseURL: URL?) -> URL? {
        guard let functionsBaseURL else { return installURL }
        return functionsBaseURL
            .appendingPathComponent("functions")
            .appendingPathComponent("v1")
            .appendingPathComponent(redirectFunctionName)
    }

    /// Matches the folder under `supabase/functions/`. Renaming one without
    /// the other leaves every new user's install button on a 404.
    public static let redirectFunctionName = "capture-shortcut"

    /// Two things to do, in order: get the shortcut, then point a Wallet
    /// automation at it.
    ///
    /// **It used to be six steps of variable mapping** — dragging `Merchant`,
    /// `Amount` and `Card or Pass` into an action by hand, which is where
    /// nearly every setup went wrong. Shipping the shortcut prebuilt
    /// deleted that entire half: there is now nothing to map and nothing to
    /// mistype.
    public static let steps: [WalkthroughStep] = [
        WalkthroughStep(
            id: 1,
            title: "Add the Keepo Capture shortcut",
            detail: "Tap Add Shortcut. It arrives ready to use — there is nothing to set up inside it.",
            clip: "walkthrough-1-add-shortcut"
        ),
        WalkthroughStep(
            id: 2,
            title: "In Shortcuts, open Automation and tap +",
            detail: "Automation is the middle tab at the bottom of the Shortcuts app.",
            clip: "walkthrough-2-new-automation"
        ),
        WalkthroughStep(
            id: 3,
            title: "Choose Wallet, then pick the cards to track",
            detail: "Pick every card you want Keepo to see. You can change this later.",
            clip: "walkthrough-3-choose-wallet"
        ),
        WalkthroughStep(
            id: 4,
            title: "Choose Run Immediately, then Run Shortcut → Keepo Capture",
            detail: "Run Immediately is what makes a purchase arrive without you confirming anything.",
            clip: "walkthrough-4-run-shortcut"
        )
    ]
}

/// One instruction: what to do, why, and — when it has been recorded — a
/// silent looping clip of it being done.
public struct WalkthroughStep: Identifiable, Sendable, Equatable {
    public let id: Int
    public let title: String
    /// One line. The clip shows the *where*; this says the *why*, which is
    /// the part a video cannot carry.
    public let detail: String
    /// The bundled resource's base name, or `nil` for a step whose clip has
    /// not been recorded yet. A name here is **not** a promise the file
    /// exists — the view checks, and falls back to a poster — so the flow
    /// builds and runs against an empty `videos/` folder.
    public let clip: String?

    public init(id: Int, title: String, detail: String, clip: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.clip = clip
    }
}
