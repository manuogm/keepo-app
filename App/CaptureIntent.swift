import AppIntents
import Foundation
import KeepoCore
import SwiftData
import UserNotifications

/// The Wallet automation's App Intent — declared in the app target (not an
/// extension), which is why it can reach `OfflineStore.makeContainer()`'s
/// single, memoized `ModelContainer` directly. Three parameters only — the
/// minimum a user has to map by hand when wiring the Shortcuts automation;
/// everything else (date, account via card, category via merchant history)
/// is derived automatically (app-architecture.md §4).
///
/// `openAppWhenRun = false` — this intent does no UI work and must never
/// interrupt whatever the user is doing at the register; the tap-to-review
/// notification (`notify(for:...)` below) is the entire review surface.
///
/// Uses the exact same Keychain-backed client `SessionStore` does
/// (`config.isLocal ? nil : KeychainSessionStorage()`) — a bare
/// `makeSupabaseClient(config:)` call here would read/write a *different*
/// Keychain item than where sign-in actually stored the session, which was
/// the root cause of every capture failing outright before this fix: an
/// unauthenticated client, rejected by RLS.
///
/// Only ever writes a pending stub — never reads a balance, a total, or any
/// existing transaction (spec: App Intents execute outside the biometric
/// lock; a richer read surface here is a leak waiting to happen). The one
/// exception is `client.auth.session.user.id`, which is not user financial
/// data — it only scopes `CaptureLocalWrite`'s on-device lookups (card →
/// account, merchant → category) to the signed-in user's own rows, exactly
/// what the server-side RPC already does via `auth.uid()`.
struct CaptureIntent: AppIntent {
    static var title: LocalizedStringResource { "Log Apple Pay Purchase" }
    static var description: IntentDescription {
        IntentDescription("Captures a pending transaction from a Wallet automation for review in Keepo.")
    }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Card")
    var card: String
    @Parameter(title: "Merchant")
    var merchant: String
    @Parameter(title: "Amount")
    var amount: String

    func perform() async throws -> some IntentResult {
        do {
            let config = try SupabaseConfig.fromInfoPlist()
            let client = makeSupabaseClient(
                config: config, localStorage: config.isLocal ? nil : KeychainSessionStorage()
            )
            let swiftDataContext = ModelContext(try OfflineStore.makeContainer())
            let dbQueue = try LocalStore.makeQueue()
            await OutboxMigration.migrateIfNeeded(swiftDataContext: swiftDataContext, to: dbQueue)
            let outbox = await Outbox(dbQueue: dbQueue, sender: LiveOutboxSender(client: client))

            guard let parsedAmount = AmountParser.parseFormattedCurrency(amount) else {
                await notify(title: "Capture failed", body: "Couldn't read the amount \"\(amount)\".")
                return .result()
            }

            // The automation's fire time, never sync time — it must
            // survive an offline delay before this even runs.
            let occurredAt = Date()
            let merchantNormalized = MerchantNormalizer.normalize(merchant)
            let externalId = CaptureIdentity.externalId(
                card: card, amount: parsedAmount, merchant: merchantNormalized, at: occurredAt
            )
            // Fills the "Other" fallback's blind spot: if no merchant match
            // is found, this is the one place the raw merchant name still
            // shows up on the transaction itself.
            let notes = "Captured automatically — \(merchant)"
            let payload = CaptureTransactionPayload(
                id: UUID(), cardIdentifier: card, merchantRaw: merchant, merchantNormalized: merchantNormalized,
                amountE4: parsedAmount, occurredAt: occurredAt, externalId: externalId, notes: notes
            )

            let ownerId = try? await client.auth.session.user.id
            let result = await outbox.submitCaptureTransaction(payload, ownerId: ownerId)
            await notify(for: result, transactionId: payload.id, merchant: merchant, amountE4: parsedAmount)
        } catch {
            await notify(title: "Capture failed", body: UserFacingError.describe(error))
        }
        return .result()
    }

    private func notify(
        for result: OutboxCaptureResult, transactionId: UUID, merchant: String, amountE4: Int64
    ) async {
        switch result {
        case .appliedLocally(let accountName, let categoryName, let currency, let minorUnit):
            // The row exists locally either way now (account-resolved or
            // not), so this always deep-links — unlike the two fallback
            // cases below, which have nothing local to open yet.
            if let accountName, let currency {
                let amountText = MoneyFormatter.format(
                    abs(amountE4), currency: CurrencyInfo(code: currency, minorUnit: minorUnit ?? 2)
                )
                await notify(
                    title: "New expense logged automatically!",
                    body: "\(amountText) · \(categoryName) · \(accountName) — tap to review",
                    transactionId: transactionId
                )
            } else {
                // No account yet means no currency yet either — a plain
                // decimal, never a guessed currency symbol that might be
                // wrong (money rule: an unresolvable value never
                // fabricates a specific number it doesn't actually know).
                let amountText = AmountFormatter.editableString(abs(amountE4), minorUnit: 2)
                await notify(
                    title: "New expense logged automatically!",
                    body: "\(amountText) · \(categoryName) — tap to choose an account",
                    transactionId: transactionId
                )
            }
        case .applied:
            // Landed server-side; nothing local to deep-link into yet (the
            // next sync pull brings the row down) — same reasoning as the
            // `.queued` case below, just without the wait.
            await notify(title: "Purchase captured", body: "\(merchant) — check Needs Review.")
        case .queued:
            await notify(title: "Purchase queued", body: "\(merchant) will sync next time Keepo is open.")
        }
    }

    /// Capture confirmations are a "functional" notification (spec:
    /// automatic payment capture) — suppressed only at the "No
    /// Notifications" level, unlike the monthly balance reminder which
    /// needs the "Full Experience" level specifically.
    private func notify(title: String, body: String, transactionId: UUID? = nil) async {
        guard AppSettings.notificationLevel != .none else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Read by `AppDelegate.userNotificationCenter(_:didReceive:...)` to
        // deep-link straight into the prefilled review form — only set when
        // the row actually exists locally to open (`appliedLocally`'s case;
        // see that method's own comment on why the other branches don't).
        if let transactionId {
            content.userInfo = [NotificationRouter.transactionIdKey: transactionId.uuidString]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
