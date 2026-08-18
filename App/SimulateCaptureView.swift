import KeepoCore
import SwiftUI
import UserNotifications

/// Debug-only stand-in for the Wallet automation trigger, which cannot fire
/// on the Simulator. Calls the exact same `Outbox.submitCaptureTransaction`
/// path `CaptureIntent.perform()` does — this proves the capture write path
/// and the pending-review surface end to end without a physical device
/// (master plan's Phase 12 verify step).
///
/// Also schedules the same deep-linking local notification
/// `CaptureIntent.notify(...)` does for its `appliedLocally` case (same
/// `userInfo` key, same transaction id) — added so the notification-tap →
/// `AppDelegate` → `RootView` deep-link path is exercisable on the
/// Simulator, where the real Wallet automation trigger can't fire. Only
/// that one case gets a notification here, matching production: a capture
/// that fell through to the network-only fallback (`applied`/`queued`)
/// has nothing local yet to deep-link into.
#if DEBUG
struct SimulateCaptureView: View {
    let session: SessionStore

    @State private var card = "card-debug-1"
    @State private var merchant = "SQ *BLUE BOTTLE COFFEE 00042"
    @State private var amount = "$4.50"
    @State private var resultMessage: String?
    @State private var isSending = false

    var body: some View {
        Form {
            Section("Wallet trigger payload") {
                TextField("Card", text: $card)
                TextField("Merchant", text: $merchant)
                TextField("Amount (e.g. $4.50)", text: $amount)
            }

            Section {
                Button {
                    Task { await simulate() }
                } label: {
                    if isSending {
                        ProgressView()
                    } else {
                        Text("Simulate Capture")
                    }
                }
                .disabled(isSending)
            }

            if let resultMessage {
                Section("Result") {
                    Text(resultMessage)
                }
            }
        }
        .navigationTitle("Simulate Capture")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func simulate() async {
        isSending = true
        resultMessage = nil
        defer { isSending = false }

        guard let parsedAmount = AmountParser.parseFormattedCurrency(amount) else {
            resultMessage = "Couldn't parse amount \"\(amount)\"."
            return
        }

        let occurredAt = Date()
        let merchantNormalized = MerchantNormalizer.normalize(merchant)
        let externalId = CaptureIdentity.externalId(
            card: card, amount: parsedAmount, merchant: merchantNormalized, at: occurredAt
        )
        let payload = CaptureTransactionPayload(
            id: UUID(), cardIdentifier: card, merchantRaw: merchant, merchantNormalized: merchantNormalized,
            amountE4: parsedAmount, occurredAt: occurredAt, externalId: externalId,
            notes: "Paid with \(card) at \(merchant)"
        )

        switch await session.outbox.submitCaptureTransaction(payload, ownerId: session.profile?.id) {
        case .appliedLocally(let resolution):
            resultMessage = "Captured locally — \(resolution.categoryName) · \(resolution.accountName ?? "—"). "
                + "Notification scheduled — background the app and tap it to test the deep link."
            session.refresh.bump()
            await scheduleDeepLinkNotification(transactionId: payload.id)
        case .applied:
            resultMessage = "Captured — check Needs Review."
            session.refresh.bump()
        case .queued:
            resultMessage = "Offline — queued in the outbox, will send on next drain."
        }
    }

    private func scheduleDeepLinkNotification(transactionId: UUID) async {
        let content = UNMutableNotificationContent()
        content.title = "New expense logged automatically!"
        content.body = "\(merchant) — tap to review (Simulator test)"
        content.sound = .default
        content.userInfo = [NotificationRouter.transactionIdKey: transactionId.uuidString]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
#endif
