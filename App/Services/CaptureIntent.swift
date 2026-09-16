import AppIntents
import Foundation
import KeepoCore
import Supabase
import UserNotifications

/// The Wallet automation's App Intent — declared in the app target (not an
/// extension), which is why `CaptureEnvironment.makeOutbox()` can reach
/// `OfflineStore.makeContainer()`'s single, memoized `ModelContainer`
/// directly. Three parameters only — the
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
    // Mirrored by `ShortcutsWalkthrough.actionName`, which is what the
    // manual fallback tells the user to look for in the action list.
    static var title: LocalizedStringResource { "Log Apple Pay Purchase" }
    static var description: IntentDescription {
        IntentDescription("Captures a pending transaction from a Wallet automation for review in Keepo.")
    }
    static var openAppWhenRun: Bool { false }

    // **These three property names are a frozen public API.** Shortcuts
    // binds a saved shortcut's fields to the intent by property name, so
    // renaming one breaks every copy of "Keepo Capture" already on every
    // user's phone — silently, with the field simply going empty, which
    // `performOnboardingTest` below would then have to tell them about.
    // The titles are display only and may change; these may not. The same
    // goes for the type name `CaptureIntent` itself.
    @Parameter(title: "Card")
    var card: String
    @Parameter(title: "Merchant")
    var merchant: String
    @Parameter(title: "Amount")
    var amount: String

    func perform() async throws -> some IntentResult {
        do {
            let environment = try await CaptureEnvironment.makeOutbox()
            let outbox = environment.outbox
            let client = environment.client

            if isEmptyInvocation {
                await performOnboardingTest(client: client, outbox: outbox)
                return .result()
            }

            guard let parsedAmount = AmountParser.parseFormattedCurrency(amount) else {
                await notify(title: "Capture failed", body: "Couldn't read the amount \"\(amount)\".")
                return .result()
            }

            // The automation's fire time, never sync time — it must
            // survive an offline delay before this even runs.
            let occurredAt = Date()
            // What currency Wallet formatted the amount in, when that can
            // be known for certain. Only ever a *report* — the account this
            // card maps to is what decides whether it means anything, and
            // both `CaptureLocalWrite` and `capture_transaction` re-check it
            // against the supported set rather than trusting this.
            let detectedCurrency = try? await environment.dbQueue.read { database in
                CurrencyDetector.detect(
                    in: amount, supported: try LocalTableQueries.currencies(database).map(\.code)
                )
            }
            let merchantNormalized = MerchantNormalizer.normalize(merchant)
            let externalId = CaptureIdentity.externalId(
                card: card, amount: parsedAmount, merchant: merchantNormalized, at: occurredAt
            )
            // Fills the "Other" fallback's blind spot: if no merchant match
            // is found, this is the one place the raw merchant name still
            // shows up on the transaction itself. Card name too, since a
            // household or multi-card user needs to know which card this
            // charge actually came from.
            let notes = "Paid with \(card) at \(merchant)"
            let payload = CaptureTransactionPayload(
                id: CaptureIdentity.transactionId(forExternalId: externalId), cardIdentifier: card,
                merchantRaw: merchant, merchantNormalized: merchantNormalized, amountE4: parsedAmount,
                occurredAt: occurredAt, externalId: externalId, notes: notes,
                detectedCurrency: detectedCurrency ?? nil
            )

            let ownerId = try? await client.auth.session.user.id
            let result = await outbox.submitCaptureTransaction(payload, ownerId: ownerId)
            // The first capture that actually arrives is what proves the
            // Wallet automation exists and is bound to the right cards —
            // the one half the test button can never check. Write-driven,
            // so it is recorded here rather than by whichever screen
            // happens to be watching.
            AppSettings.markCaptureVerifiedIfNeeded()
            // Wake a foregrounded RootView (C-09) — the local write always
            // lands regardless of `result` (Phase 12), so this fires
            // unconditionally rather than only on the network-backed cases.
            CaptureNotify.post()
            await notify(for: result, transactionId: payload.id, amountE4: parsedAmount)
        } catch {
            await notify(title: "Capture failed", body: UserFacingError.describe(error))
        }
        return .result()
    }

    // MARK: - The onboarding test

    /// All three fields empty. The published shortcut's own header says
    /// *"If there's no input: Continue"*, so this is what reaches us when
    /// Keepo runs it directly through `x-callback-url` — and also what
    /// reaches us when a real automation's Wallet keys are mis-spelled,
    /// which is why the window below decides which of the two it is.
    private var isEmptyInvocation: Bool {
        card.isEmpty && merchant.isEmpty && amount.isEmpty
    }

    /// Writes the local-only test capture, or reports the failure this
    /// actually is.
    ///
    /// **The window is the whole safety property.** Outside it, an
    /// all-empty invocation is a real automation delivering nothing —
    /// exactly the broken setup the test exists to catch — so it must be
    /// reported as broken rather than quietly answered with canned data.
    /// Inside it, Keepo asked for this seconds ago.
    private func performOnboardingTest(client: SupabaseClient, outbox: Outbox) async {
        guard CaptureTestSession.isExpectingTest else {
            await notify(
                title: "Capture failed",
                body: "The automation ran but sent nothing. Check that Merchant, Amount and Card "
                    + "are mapped in your Wallet automation."
            )
            return
        }
        guard let ownerId = try? await client.auth.session.user.id else {
            await notify(title: "Capture failed", body: "Sign in to Keepo and try the test again.")
            return
        }

        let occurredAt = Date()
        let merchantNormalized = MerchantNormalizer.normalize(CaptureIdentity.testMerchant)
        let externalId = CaptureIdentity.externalId(
            card: CaptureIdentity.testCardIdentifier, amount: CaptureIdentity.testAmountE4,
            merchant: merchantNormalized, at: occurredAt
        )
        let payload = CaptureTransactionPayload(
            id: CaptureIdentity.transactionId(forExternalId: externalId),
            cardIdentifier: CaptureIdentity.testCardIdentifier,
            merchantRaw: CaptureIdentity.testMerchant, merchantNormalized: merchantNormalized,
            amountE4: CaptureIdentity.testAmountE4, occurredAt: occurredAt, externalId: externalId,
            notes: "Keepo's own test purchase — delete it whenever you like.", detectedCurrency: nil
        )
        let resolution = await outbox.submitTestCaptureTransaction(payload, ownerId: ownerId)
        // Posted whether or not the row resolved: the setup screen is
        // waiting on this to go and look, and "it ran and wrote nothing" is
        // an answer it needs as much as success.
        CaptureNotify.post()
        guard let resolution else {
            await notify(title: "Test failed", body: "Keepo could not file the test purchase. Try again in a moment.")
            return
        }
        // Deliberately the same notification a real capture produces,
        // quick actions and all — the point of the test is to show what a
        // purchase looks like, and a special-cased "test succeeded" alert
        // would demonstrate nothing.
        await CaptureNotificationScheduler.scheduleAppliedLocally(
            resolution: resolution, amountE4: CaptureIdentity.testAmountE4, transactionId: payload.id
        )
    }

    private func notify(for result: OutboxCaptureResult, transactionId: UUID, amountE4: Int64) async {
        switch result {
        case .appliedLocally(let resolution):
            // The row exists locally either way now (account-resolved or
            // not), so this always deep-links — unlike the two fallback
            // cases below, which have nothing local to open yet. Routed
            // through `CaptureNotificationScheduler` rather than this
            // file's own `notify(title:body:transactionId:)` — this is the
            // one branch that gets quick-action buttons.
            await CaptureNotificationScheduler.scheduleAppliedLocally(
                resolution: resolution, amountE4: amountE4, transactionId: transactionId
            )
        case .applied:
            // Landed server-side; nothing local to deep-link into yet (the
            // next sync pull brings the row down) — same reasoning as the
            // `.queued` case below, just without the wait.
            let content = CaptureNotificationCopy.applied(amountE4: amountE4)
            await notify(title: content.title, body: content.body)
        case .queued:
            let content = CaptureNotificationCopy.queued(amountE4: amountE4)
            await notify(title: content.title, body: content.body)
        }
    }

    /// Capture confirmations are a "functional" notification (spec:
    /// automatic payment capture) — suppressed only at the "No
    /// Notifications" level, unlike the monthly balance reminder which
    /// needs the "Full Experience" level specifically. Also gates on the
    /// live system `authorizationStatus` (C-06) rather than trusting the
    /// stored preference alone — `notificationLevel` defaults to `.full`
    /// on a fresh install regardless of whether iOS has ever actually been
    /// asked, and `UNUserNotificationCenter.add` no-ops silently rather
    /// than erroring when it hasn't.
    private func notify(title: String, body: String, transactionId: UUID? = nil) async {
        guard AppSettings.notificationLevel != .none else { return }
        guard await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized
        else { return }
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
