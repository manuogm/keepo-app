import Foundation
import GRDB
import KeepoCore
import Supabase
import SwiftData

/// The bootstrap `CaptureIntent.perform()` needs to reach a working
/// `Outbox` (Supabase client on the exact Keychain-backed session storage
/// sign-in uses, the local GRDB queue, the one-time legacy SwiftData
/// migration check) — extracted so `CaptureQuickActionHandler`'s background
/// notification-action handling can reach the same `Outbox` the same way,
/// rather than duplicating this sequence a second time. One bootstrap, two
/// callers; a future session-handling change only needs updating once.
enum CaptureEnvironment {
    struct Environment {
        let outbox: Outbox
        let dbQueue: DatabaseQueue
        let client: SupabaseClient
    }

    static func makeOutbox() async throws -> Environment {
        let config = try SupabaseConfig.fromInfoPlist()
        let client = makeSupabaseClient(
            config: config, localStorage: config.isLocal ? nil : KeychainSessionStorage()
        )
        let dbQueue = try LocalStore.makeQueue()
        // X-03: skip opening `OfflineStore`'s `ModelContainer` at all once
        // the legacy SwiftData outbox is confirmed drained.
        if !OutboxMigration.isDone() {
            let swiftDataContext = ModelContext(try OfflineStore.makeContainer())
            await OutboxMigration.migrateIfNeeded(swiftDataContext: swiftDataContext, to: dbQueue)
        }
        let outbox = await Outbox(dbQueue: dbQueue, sender: LiveOutboxSender(client: client))
        // This is the call site that actually matters for
        // `Outbox+CaptureRecovery.swift`'s own header comment: a quick
        // action attempts its write immediately, with no drain first, so a
        // capture whose create is still queued elsewhere (device briefly
        // offline moments earlier) can race ahead of it and hit "not found."
        // Cheap when there's nothing to repair — one local read, no network
        // — so it's safe to run before every quick action, not just once
        // per app launch.
        await outbox.repairLegacyCaptureQueueIfNeeded()
        return Environment(outbox: outbox, dbQueue: dbQueue, client: client)
    }
}
