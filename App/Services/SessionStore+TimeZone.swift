import Foundation
import KeepoCore

// Which calendar this device is in, reported to the server so a recurring
// rule's date can become the right instant. Split out of SessionStore.swift
// for the project's file-length lint.

extension SessionStore {
    /// Tells the server which calendar this device is in, when that has
    /// changed — and fixes what was already materialized against the old one.
    ///
    /// `materialize_recurring` is the only reader: a rule due "on the 20th"
    /// has to become an instant, and no fixed instant is the 20th everywhere,
    /// so the occurrence is stored at the owner's local midnight (migration
    /// 20260928100000). Until this runs the profile carries the 'UTC' default,
    /// which reproduces the old behaviour exactly rather than guessing.
    ///
    /// **Silent on failure, deliberately.** Every other failed write in this
    /// app raises an alert, because the user asked for it and it did not
    /// happen. Nobody asks for this — it is housekeeping the app does on its
    /// own behalf, it costs nothing to skip, and it retries on the next
    /// launch. An alert here would be the app interrupting to report a job the
    /// user never started.
    ///
    /// Only fires when the zone actually differs, so the common launch makes
    /// no write at all: a PATCH per launch would bump `profiles.sync_seq` and
    /// make every other device re-pull the profile for nothing.
    ///
    /// Returns the re-fetched profile when it wrote one, `nil` otherwise —
    /// rather than assigning `profile` here, which is `private(set)` and worth
    /// keeping that way: widening it so one housekeeping call could write it
    /// would open it to every screen in the app.
    func reconcileTimeZone(
        _ profile: PublicSchema.ProfilesSelect, userId: UUID
    ) async -> PublicSchema.ProfilesSelect? {
        let deviceZone = TimeZone.current.identifier
        guard profile.timeZone != deviceZone else { return nil }
        do {
            try await ProfileRepository.updateTimeZone(client: client, userId: userId, timeZone: deviceZone)
            // Only after the zone is known can the server tell a row that
            // renders on the wrong day from one that does not.
            try await ProfileRepository.realignRecurringOccurrences(client: client)
            let refreshed = try await ProfileRepository.fetchOwn(client: client, userId: userId)
            refresh.bump()
            return refreshed
        } catch {
            // See above: nothing to report, nothing lost, retried next launch.
            return nil
        }
    }
}
