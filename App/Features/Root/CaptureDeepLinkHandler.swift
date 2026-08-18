import KeepoCore
import SwiftUI

/// Invisible helper view, attached via `.background` on `RootView`, that
/// turns a tapped capture notification into the same "review a capture"
/// sheet `NeedsReviewView.openForReview` opens — `TransactionFormView` in
/// edit mode, per app-architecture.md, not a bespoke screen.
///
/// A cold launch from a notification tap sets `router.pendingCaptureId`
/// before `session.phase` ever reaches `.ready` — retried on both the
/// router firing and `session.phase` changing, so whichever lands second
/// is the one that actually opens the sheet.
struct CaptureDeepLinkHandler: View {
    let session: SessionStore

    @State private var router = NotificationRouter.shared
    @State private var deepLinkedCapture: PublicSchema.TransactionsWithDetailsSelect?
    @State private var showDeepLinkedCapture = false

    var body: some View {
        Color.clear
            .sheet(isPresented: $showDeepLinkedCapture) {
                if let deepLinkedCapture {
                    TransactionFormView(session: session, mode: .edit(deepLinkedCapture, sibling: nil)) {
                        session.refresh.bump()
                    }
                }
            }
            .onChange(of: router.pendingCaptureId) { _, _ in Task { await openPendingCaptureIfNeeded() } }
            .onChange(of: session.phase) { _, _ in Task { await openPendingCaptureIfNeeded() } }
    }

    /// Only fires once `.ready` (needs `session.profile`/`session.dbQueue`);
    /// `pendingCaptureId` is left set until it resolves, so the retry from
    /// `session.phase` changing is what actually opens it on a cold launch.
    ///
    /// `@MainActor` explicitly — every other screen's identical
    /// read-then-mutate-@State pattern gets this for free from `.task {}`,
    /// whose closure SwiftUI itself types as `@MainActor`. This function is
    /// started from a plain `Task { }` inside `.onChange`'s (non-`@MainActor`)
    /// closure instead, which doesn't carry that guarantee — the `@State`
    /// writes below could resume on whatever thread `session.dbQueue.read`'s
    /// continuation happens to land on, which crashed with "Call must be
    /// made on main thread" (reported: notification tap → app resumes into
    /// a stuck privacy curtain / crash, deep-link never completing).
    @MainActor
    private func openPendingCaptureIfNeeded() async {
        guard
            session.phase == .ready,
            let id = router.pendingCaptureId,
            let ownerId = session.profile?.id,
            let baseCurrency = session.profile?.baseCurrency
        else { return }
        router.pendingCaptureId = nil
        guard let transaction = try? await session.dbQueue.read({ database in
            try LocalTransactionRow.fetchOne(
                database, id: id.uuidString, baseCurrency: baseCurrency, ownerId: ownerId.uuidString
            )
        }) else { return }
        deepLinkedCapture = transaction
        showDeepLinkedCapture = true
    }
}
