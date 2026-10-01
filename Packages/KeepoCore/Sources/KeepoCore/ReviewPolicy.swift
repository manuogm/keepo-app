import Foundation

/// When Keepo is allowed to ask for a rating, as one pure decision.
///
/// **It is a separate type because the answer is a judgement, not a
/// mechanism.** `requestReview` is a black box — no callback, no return
/// value, capped by the system at three displays per user per 365 days,
/// always shown in debug builds, never in TestFlight, unpredictable in
/// production. Nothing downstream can tell whether an ask worked, so the
/// only thing that can be got right is *when* Keepo asks, and that has to
/// be testable without a UI or a clock.
///
/// **Never during onboarding.** Apple's HIG says so outright, and the
/// reason is the one that matters here: a rating given before any value has
/// been delivered is a rating of the onboarding. A new listing's first
/// ratings are also disproportionately weighted, so harvesting them from
/// users who have not seen a single captured transaction spends the most
/// valuable asset a launch has on the least informed possible reviewers.
public enum ReviewPolicy {
    /// **Two captures reviewed, in the user's lifetime.** Someone who has
    /// reviewed exactly one captured purchase has thin grounds to rate on;
    /// two means they have watched the trick work twice.
    public static let lifetimeCapturesBar = 2

    /// The fallback's clock, read from `profiles.created_at` — which
    /// already exists, rather than inventing a local first-launch key.
    public static let daysSinceSignupForFallback = 7

    /// **Both paths are gated on this, not just the fallback.**
    ///
    /// The system caps `requestReview` at three displays per 365 days and
    /// gives no way to observe them, so asking more often than roughly
    /// every four months cannot show anything extra — it can only burn a
    /// display invisibly, at a worse moment than the one it would have been
    /// saved for. 365 ÷ 120 ≈ 3 is the deliberate alignment.
    public static let reAskWindowDays = 120

    /// Everything persisted about asking. `hasAskedEver` is deliberately
    /// absent: `lastRequestedAt == nil` already means it exactly, and a
    /// second field that can disagree with the first is a bug waiting for
    /// a release note.
    public struct State: Equatable, Sendable {
        /// Lifetime, and **excluding onboarding's own test capture** — the
        /// increment's call site skips the reserved identifier, or setup
        /// would contribute to the bar it is supposed to sit behind.
        public var capturesReviewed: Int
        /// Set at the write that cleared the pending inbox, asked for
        /// later. See `shouldArm`.
        public var isArmed: Bool
        public var lastRequestedAt: Date?

        public init(capturesReviewed: Int = 0, isArmed: Bool = false, lastRequestedAt: Date? = nil) {
            self.capturesReviewed = capturesReviewed
            self.isArmed = isArmed
            self.lastRequestedAt = lastRequestedAt
        }
    }

    /// Whether the write that just resolved a capture should arm the
    /// prompt.
    ///
    /// **Armed at the write, never by watching a count**, and that is the
    /// correctness fix rather than a refinement. Quick actions resolve a
    /// capture from a notification **while the app is backgrounded**, so
    /// the inbox genuinely clears with nobody looking — a prompt fired
    /// there is fired at nobody (false positive), and a rule that watched
    /// `needsReviewCount` for a 1 → 0 transition would never observe that
    /// clear at all, so a user who habitually clears from notifications
    /// would be asked *never* (false negative, the worse one). Deciding at
    /// the write behaves identically foregrounded or backgrounded.
    ///
    /// - Parameter pendingCapturesRemaining: after the write. Zero is the
    ///   inbox being clear of captures.
    ///
    /// The "batch contained a real capture" condition the inbox rule needs
    /// is free here: this is only ever called *from* a capture's own write.
    /// Asking the moment someone finishes resolving a **sync conflict** —
    /// the other thing that inbox holds — would be asking them to rate the
    /// app right after it caused them a problem.
    public static func shouldArm(capturesReviewed: Int, pendingCapturesRemaining: Int) -> Bool {
        pendingCapturesRemaining == 0 && capturesReviewed >= lifetimeCapturesBar
    }

    /// Whether to ask on this foreground beat.
    ///
    /// - Parameter signedUpAt: `profiles.created_at`. `nil` disables the
    ///   fallback rather than enabling it — an unknown signup date is not
    ///   evidence that a week has passed.
    public static func shouldAsk(
        state: State, signedUpAt: Date?, now: Date = Date(), calendar: Calendar = .current
    ) -> Bool {
        guard isOutsideReAskWindow(state.lastRequestedAt, now: now, calendar: calendar) else { return false }
        if state.isArmed { return true }
        guard let signedUpAt,
              let earliest = calendar.date(byAdding: .day, value: daysSinceSignupForFallback, to: signedUpAt)
        else { return false }
        // Deliberately **not** gated on transaction count, so a user who
        // never sets capture up is still eventually asked.
        return now >= earliest
    }

    private static func isOutsideReAskWindow(_ last: Date?, now: Date, calendar: Calendar) -> Bool {
        guard let last else { return true }
        guard let next = calendar.date(byAdding: .day, value: reAskWindowDays, to: last) else { return true }
        return now >= next
    }
}

/// Where the App Store's own write-a-review sheet lives.
///
/// **The only guaranteed-visible path to rating Keepo.** `requestReview`
/// may silently decline to show anything; this link always opens the sheet,
/// with no cap — at the cost of leaving the app. That trade is right for a
/// permanent row somebody goes looking for, and wrong for an interruption,
/// which is why the two are different mechanisms rather than one.
public enum AppStoreListing {
    /// **`nil` until Keepo exists in App Store Connect.** The row that
    /// links here stays hidden rather than shipping a URL that 404s — an
    /// App Store link to nothing is worse than no link, because the user
    /// has already left the app by the time they find out.
    public static let appID: String? = nil

    public static var writeReviewURL: URL? {
        guard let appID else { return nil }
        return URL(string: "https://apps.apple.com/app/id\(appID)?action=write-review")
    }
}
