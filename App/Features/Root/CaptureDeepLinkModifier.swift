import KeepoCore
import SwiftUI

/// Turns a tapped capture notification (or its "More options" quick action)
/// into the same "review a capture" sheet `NeedsReviewView.openForReview`
/// opens — `TransactionFormView` in edit mode, per app-architecture.md, not
/// a bespoke screen.
///
/// Applied to `MainTabView`, deliberately, and NOT to `RootView` where it
/// used to live as an invisible `Color.clear` in `.background`. Presenting a
/// sheet from a detached zero-size view that isn't an ancestor of the
/// `TabView` caused both bugs found in device testing:
///
/// 1. **Blank sheet.** `.sheet(isPresented:)` with an `if let` inside its
///    content closure races its own state: the closure SwiftUI presents with
///    can be the one captured before the transaction was assigned, so it
///    rendered the empty `else` branch — an empty sheet, with the row itself
///    perfectly intact underneath (visible the moment the user opened the
///    same transaction from the list). `.sheet(item:)` hands the value to
///    the closure instead of having it read back state, which is why every
///    other screen here (`TransactionsListView`, `NeedsReviewView`) already
///    uses it and never showed this.
/// 2. **Greyed tab bar.** UIKit sets `tintAdjustmentMode = .dimmed` on
///    everything behind a modal and restores it on dismissal by walking the
///    presenting controller's hierarchy. Presented from outside the
///    `TabView`, the restore never reached the tab bar, which stayed grey
///    until a tab switch forced a re-render.
///
/// `session.phase` is no longer part of the retry: this only exists while
/// `MainTabView` does, which is only ever the `.ready` phase, so `.task`
/// covers a cold launch whose id was already set before the tabs appeared
/// and `.onChange` covers one that arrives while they're on screen.
struct CaptureDeepLinkModifier: ViewModifier {
    let session: SessionStore

    @State private var router = NotificationRouter.shared
    @State private var deepLinkedCapture: PublicSchema.TransactionsWithDetailsSelect?

    func body(content: Content) -> some View {
        content
            .sheet(item: $deepLinkedCapture) { transaction in
                TransactionFormView(session: session, mode: .edit(transaction, sibling: nil)) {
                    session.refresh.bump()
                }
            }
            .task { await openPendingCaptureIfNeeded() }
            .onChange(of: router.pendingCaptureId) { _, _ in Task { await openPendingCaptureIfNeeded() } }
    }

    /// `@MainActor` explicitly — `.onChange`'s closure isn't typed as
    /// main-actor the way `.task`'s is, so without this the `@State` write
    /// below could resume on whatever thread `session.dbQueue.read`'s
    /// continuation landed on, which crashed with "Call must be made on main
    /// thread" (reported: notification tap → app resumes into a stuck
    /// privacy curtain, deep link never completing).
    @MainActor
    private func openPendingCaptureIfNeeded() async {
        guard
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
    }
}

extension View {
    func captureDeepLink(session: SessionStore) -> some View {
        modifier(CaptureDeepLinkModifier(session: session))
    }
}
