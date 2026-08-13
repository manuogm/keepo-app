import AppIntents
import Foundation
import KeepoCore
import SwiftData
import UserNotifications

/// The Wallet automation's App Intent — declared in the app target (not an
/// extension), which is why it can reach `OfflineStore.makeContainer()`'s
/// single, memoized `ModelContainer` directly. Parameters mirror the
/// trigger's own five Shortcuts variables exactly (app-architecture.md
/// §4); only `Merchant` and `Amount` feed the schema — `Transaction`/`Name`
/// have no columns to land in and exist here purely so the intent's
/// parameter list matches what Shortcuts actually hands it.
///
/// Only ever writes a pending stub via `Outbox.submitCaptureTransaction` —
/// never reads a balance, a total, or any existing transaction (spec:
/// App Intents execute outside the biometric lock; a richer read surface
/// here is a leak waiting to happen).
struct CaptureIntent: AppIntent {
    static var title: LocalizedStringResource { "Log Apple Pay Purchase" }
    static var description: IntentDescription {
        IntentDescription("Captures a pending transaction from a Wallet automation for review in Keepo.")
    }

    @Parameter(title: "Transaction")
    var transaction: String
    @Parameter(title: "Card")
    var card: String
    @Parameter(title: "Merchant")
    var merchant: String
    @Parameter(title: "Amount")
    var amount: String
    @Parameter(title: "Name")
    var name: String

    func perform() async throws -> some IntentResult {
        do {
            let config = try SupabaseConfig.fromInfoPlist()
            let client = makeSupabaseClient(config: config)
            let context = ModelContext(try OfflineStore.makeContainer())
            let outbox = await Outbox(context: context, sender: LiveOutboxSender(client: client))

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
            let payload = CaptureTransactionPayload(
                id: UUID(), cardIdentifier: card, merchantRaw: merchant, merchantNormalized: merchantNormalized,
                amountE4: parsedAmount, occurredAt: occurredAt, externalId: externalId
            )

            await notify(for: await outbox.submitCaptureTransaction(payload), merchant: merchant)
        } catch {
            await notify(title: "Capture failed", body: UserFacingError.describe(error))
        }
        return .result()
    }

    private func notify(for result: OutboxCaptureResult, merchant: String) async {
        switch result {
        case .applied(mapped: true):
            await notify(title: "Purchase captured", body: "\(merchant) — tap to review in Keepo.")
        case .applied(mapped: false):
            await notify(
                title: "Card not yet mapped", body: "Map this card to an account in Keepo to capture \(merchant)."
            )
        case .queued:
            await notify(title: "Purchase queued", body: "\(merchant) will sync next time Keepo is open.")
        }
    }

    /// Capture confirmations are a "functional" notification (spec:
    /// automatic payment capture) — suppressed only at the "No
    /// Notifications" level, unlike the monthly balance reminder which
    /// needs the "Full Experience" level specifically.
    private func notify(title: String, body: String) async {
        guard AppSettings.notificationLevel != .none else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
