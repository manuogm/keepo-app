import Foundation
import GRDB
import KeepoCore

/// The persisted half of the rating ask: what `ReviewPolicy` decides on,
/// and the two moments that change it.
///
/// **Plain statics over `UserDefaults`, not an `@Observable` object**, for
/// the same reason `AppSettings` is: one of the two moments happens on a
/// capture's write, which runs from a notification quick action with the
/// app backgrounded and no view alive to own state. A store that only
/// existed while a screen did would miss exactly the case the arming rule
/// was written for.
///
/// Nothing here calls `requestReview` — that needs a foreground-active
/// scene and SwiftUI's environment, so it belongs at the one call site that
/// has both (`MainTabView`). This decides *whether*.
enum ReviewPrompter {
    // MARK: - Reading

    static var state: ReviewPolicy.State {
        let defaults = UserDefaults.standard
        return ReviewPolicy.State(
            capturesReviewed: defaults.integer(forKey: AppSettingsKeys.capturesReviewed),
            isArmed: defaults.bool(forKey: AppSettingsKeys.reviewPromptArmed),
            lastRequestedAt: defaults.object(forKey: AppSettingsKeys.lastReviewRequestAt) as? Date
        )
    }

    // MARK: - The write that resolves a capture

    /// Called immediately after a capture is confirmed or reviewed, from
    /// `Outbox` — the one choke point both the in-app path and the
    /// quick-action path already share.
    ///
    /// Does two things in one place: counts the capture toward the lifetime
    /// bar, and arms the prompt if that write left the pending inbox clear.
    /// Deciding here rather than by watching a count is what makes it
    /// behave identically foregrounded and backgrounded — see
    /// `ReviewPolicy.shouldArm`.
    static func recordCaptureResolved(id: UUID, dbQueue: DatabaseQueue) async {
        let outcome = try? await dbQueue.read { database -> (isTest: Bool, remaining: Int) in
            let card = try String.fetchOne(
                database, sql: "SELECT card_identifier FROM transactions WHERE id = ?",
                arguments: [id.uuidString]
            )
            let remaining = try Int.fetchOne(
                database,
                sql: """
                SELECT COUNT(*) FROM transactions
                WHERE source = 'capture' AND status = 'pending' AND deleted_at IS NULL
                      AND (card_identifier IS NULL OR card_identifier <> ?)
                """,
                arguments: [CaptureIdentity.testCardIdentifier]
            ) ?? 0
            return (card == CaptureIdentity.testCardIdentifier, remaining)
        }
        guard let outcome else { return }

        // **Onboarding's own test capture must not count toward the bar it
        // sits behind.** It never reaches the server's inbox, so it cannot
        // arm the condition — but it is a real local row and the
        // transactions list can confirm one, which would otherwise let
        // setup contribute to its own gate.
        guard !outcome.isTest else { return }

        let defaults = UserDefaults.standard
        let reviewed = defaults.integer(forKey: AppSettingsKeys.capturesReviewed) + 1
        defaults.set(reviewed, forKey: AppSettingsKeys.capturesReviewed)

        if ReviewPolicy.shouldArm(capturesReviewed: reviewed, pendingCapturesRemaining: outcome.remaining) {
            defaults.set(true, forKey: AppSettingsKeys.reviewPromptArmed)
        }
    }

    // MARK: - The foreground beat

    static func isDue(signedUpAt: Date?) -> Bool {
        ReviewPolicy.shouldAsk(state: state, signedUpAt: signedUpAt)
    }

    /// Called right after `requestReview` — whether or not the system
    /// actually displayed anything, because there is no way to find out and
    /// a call that showed nothing still has to start the re-ask clock.
    /// Clearing the armed flag is what makes each arming one-shot.
    static func markAsked() {
        let defaults = UserDefaults.standard
        defaults.set(Date(), forKey: AppSettingsKeys.lastReviewRequestAt)
        defaults.set(false, forKey: AppSettingsKeys.reviewPromptArmed)
    }
}
