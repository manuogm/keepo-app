import Foundation
import Testing
@testable import KeepoCore

/// Every gate on the rating ask, and the two bugs the arm-and-defer shape
/// exists to close.
///
/// This is worth testing more than most pure logic is, because the thing it
/// controls is unobservable: `requestReview` has no callback and no return
/// value, is capped at three displays per year by a system that reports
/// neither, and behaves differently in debug, TestFlight and production. So
/// the only part that can be verified at all is the decision, and it has to
/// be verified here.
@Suite("Review policy")
struct ReviewPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Gregorian/UTC, fixed. The policy does **calendar** day arithmetic,
    /// not 86,400-second arithmetic — "120 days" means 120 days on the
    /// user's calendar, which is an hour shorter or longer across a DST
    /// boundary. Counting back in raw seconds here made the boundary case
    /// pass or fail depending on the machine's time zone and the month.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    private func daysAgo(_ days: Int) -> Date {
        calendar.date(byAdding: .day, value: -days, to: now) ?? now
    }

    // MARK: - Arming

    /// The primary trigger: the write that leaves the pending inbox clear,
    /// by a user who has reviewed enough captures to have an opinion.
    @Test("clearing the last pending capture arms, once the lifetime bar is met")
    func armsOnAClearedInbox() {
        #expect(ReviewPolicy.shouldArm(capturesReviewed: 2, pendingCapturesRemaining: 0))
        #expect(ReviewPolicy.shouldArm(capturesReviewed: 9, pendingCapturesRemaining: 0))
    }

    /// Someone who has reviewed exactly one captured purchase has thin
    /// grounds to rate on.
    @Test("one capture reviewed is not enough, however clear the inbox")
    func lifetimeBar() {
        #expect(!ReviewPolicy.shouldArm(capturesReviewed: 1, pendingCapturesRemaining: 0))
        #expect(!ReviewPolicy.shouldArm(capturesReviewed: 0, pendingCapturesRemaining: 0))
    }

    @Test("an inbox with captures still in it never arms")
    func inboxMustBeClear() {
        #expect(!ReviewPolicy.shouldArm(capturesReviewed: 5, pendingCapturesRemaining: 1))
    }

    // MARK: - Asking

    @Test("an armed prompt is asked on the next clean beat")
    func armedAsks() {
        let state = ReviewPolicy.State(capturesReviewed: 2, isArmed: true)
        #expect(ReviewPolicy.shouldAsk(state: state, signedUpAt: daysAgo(1), now: now, calendar: calendar))
    }

    /// The armed path is gated by the re-ask window too, not only the
    /// fallback. The system allows three displays a year and reports none
    /// of them, so asking more often than roughly every four months can
    /// only burn one invisibly, at a worse moment than the one it would
    /// have been saved for.
    @Test("even an armed prompt waits out the re-ask window")
    func armedStillRespectsTheWindow() {
        let recent = ReviewPolicy.State(capturesReviewed: 2, isArmed: true, lastRequestedAt: daysAgo(30))
        #expect(!ReviewPolicy.shouldAsk(state: recent, signedUpAt: daysAgo(400), now: now, calendar: calendar))

        let old = ReviewPolicy.State(capturesReviewed: 2, isArmed: true, lastRequestedAt: daysAgo(121))
        #expect(ReviewPolicy.shouldAsk(state: old, signedUpAt: daysAgo(400), now: now, calendar: calendar))
    }

    /// Deliberately **not** gated on transaction count, so a user who never
    /// sets capture up is still eventually asked.
    @Test("the fallback asks a week after signup, with no captures at all")
    func fallbackAfterAWeek() {
        let state = ReviewPolicy.State()
        #expect(ReviewPolicy.shouldAsk(state: state, signedUpAt: daysAgo(7), now: now, calendar: calendar))
        #expect(!ReviewPolicy.shouldAsk(state: state, signedUpAt: daysAgo(6), now: now, calendar: calendar))
    }

    /// A rating asked for on day one rates the onboarding, not the app.
    @Test("a brand-new signup is never asked")
    func freshSignupIsNotAsked() {
        #expect(!ReviewPolicy.shouldAsk(state: ReviewPolicy.State(), signedUpAt: now, now: now, calendar: calendar))
    }

    /// An unknown signup date is not evidence that a week has passed.
    @Test("an unknown signup date disables the fallback rather than enabling it")
    func missingSignupDate() {
        #expect(!ReviewPolicy.shouldAsk(state: ReviewPolicy.State(), signedUpAt: nil, now: now, calendar: calendar))
        // Armed still asks — that path does not read the clock at all.
        let armed = ReviewPolicy.State(capturesReviewed: 2, isArmed: true)
        #expect(ReviewPolicy.shouldAsk(state: armed, signedUpAt: nil, now: now, calendar: calendar))
    }

    @Test("the fallback waits out the re-ask window too")
    func fallbackRespectsTheWindow() {
        let state = ReviewPolicy.State(lastRequestedAt: daysAgo(119))
        #expect(!ReviewPolicy.shouldAsk(state: state, signedUpAt: daysAgo(400), now: now, calendar: calendar))
        #expect(ReviewPolicy.shouldAsk(
            state: ReviewPolicy.State(lastRequestedAt: daysAgo(120)),
            signedUpAt: daysAgo(400), now: now, calendar: calendar
        ))
    }

    /// At most three asks a year, which is exactly what the system allows —
    /// so the policy can never burn a display it could not have known about.
    @Test("the window admits no more asks per year than iOS will display")
    func windowMatchesTheSystemCap() {
        #expect(365 / ReviewPolicy.reAskWindowDays == 3)
    }

    // MARK: - The listing link

    /// The only guaranteed-visible path — and it stays hidden until there
    /// is something behind it, because an App Store link to nothing is
    /// found out only after the user has already left the app.
    @Test("the write-review link is absent until the app exists in App Store Connect")
    func listingURLIsGatedOnTheAppID() {
        #expect((AppStoreListing.appID == nil) == (AppStoreListing.writeReviewURL == nil))
    }
}
