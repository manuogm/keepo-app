import KeepoCore
import SwiftUI

/// Debug-only stand-in for the Wallet automation trigger, which cannot fire
/// on the Simulator. Calls the exact same `Outbox.submitCaptureTransaction`
/// path `CaptureIntent.perform()` does — this proves the capture write path
/// and the pending-review surface end to end without a physical device
/// (master plan's Phase 12 verify step).
#if DEBUG
struct SimulateCaptureView: View {
    let session: SessionStore

    @State private var card = "card-debug-1"
    @State private var merchant = "SQ *BLUE BOTTLE COFFEE 00042"
    @State private var amount = "$4.50"
    @State private var name = ""
    @State private var transaction = ""
    @State private var resultMessage: String?
    @State private var isSending = false

    var body: some View {
        Form {
            Section("Wallet trigger payload") {
                TextField("Card", text: $card)
                TextField("Merchant", text: $merchant)
                TextField("Amount (e.g. $4.50)", text: $amount)
                TextField("Name", text: $name)
                TextField("Transaction", text: $transaction)
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
            amountE4: parsedAmount, occurredAt: occurredAt, externalId: externalId
        )

        switch await session.outbox.submitCaptureTransaction(payload) {
        case .applied(mapped: true):
            resultMessage = "Captured — check Needs Review."
            session.refresh.bump()
        case .applied(mapped: false):
            resultMessage = "Card not yet mapped — a placeholder mapping now shows in Needs Review."
            session.refresh.bump()
        case .queued:
            resultMessage = "Offline — queued in the outbox, will send on next drain."
        }
    }
}
#endif
