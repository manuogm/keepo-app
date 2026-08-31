import KeepoCore
import SwiftUI

/// Dashboard — a widget canvas the user arranges themselves, under the
/// scope banner every main screen now shares.
///
/// Two things left this screen in the redesign. The scope menu became the
/// banner's swipeable cards (`ScopeBannerView`), and the Needs Review bell
/// moved to Transactions, where the items it lists actually are. What is
/// left here is the dashboard and nothing else — adding a widget is the
/// shell's "+" button, arriving as `AppNavigation.pendingAdd`.
///
/// Reads straight off the local GRDB mirror (Phase L6) — no server round
/// trip, no payload cache, no pending-write overlay. `Outbox`'s optimistic
/// write-through means an offline (or just-submitted online) edit is
/// already in the same tables this screen queries, so there is nothing left
/// for an overlay to add: one number, one source.
struct HomeView: View {
    let session: SessionStore

    /// Owned here rather than in `SessionStore`: the arrangement is this
    /// screen's, it is device-local, and nothing outside Home reads it.
    @State private var store = DashboardStore()
    @State private var data = DashboardData()
    @State private var isLoading = true
    @State private var errorMessage: String?
    /// Lifted out of the canvas so the toolbar can offer "Done" — the canvas
    /// owns entering edit mode (via long press), the banner owns the most
    /// obvious way out of it.
    @State private var isEditing = false
    /// Lifted out of the canvas for the same reason the shell's "+" exists:
    /// the button that opens the catalogue is no longer inside the canvas.
    /// The canvas's own Add tile and blank state still write to it.
    @State private var isPickingWidget = false

    @Environment(AppNavigation.self) private var navigation: AppNavigation?
    @Environment(ScopeContext.self) private var scopeContext: ScopeContext?

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                ScopeBannerView(
                    title: "Dashboard",
                    session: session,
                    onOpenProfile: { navigation?.openProfileRoot() },
                    accessory: { doneButton }
                )
                .padding(.bottom, 10)
                // The deck's cards tilt past their own bounds mid-swipe, and
                // nothing clips them — so the banner has to win against the
                // content underneath it.
                .zIndex(1)
                // The canvas dims itself behind the widget catalogue, and
                // that dim cannot reach up here — it lives inside the
                // canvas, one `VStack` cell below. Matching it keeps the
                // screen looking like one surface going quiet rather than
                // two halves disagreeing.
                .overlay {
                    Color.black.opacity(isPickingWidget ? 0.25 : 0)
                        .allowsHitTesting(false)
                }
                .animation(.easeInOut(duration: 0.2), value: isPickingWidget)

                content
                    .fadingEdges()
            }

            if let errorMessage {
                VStack {
                    Spacer()
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                }
            }
        }
        .dropsBottomSafeArea()
        .toolbar(.hidden, for: .navigationBar)
        // Keyed on the mounted widget kinds as well as the refresh token and
        // the scope: adding or removing a widget has to reload, because the
        // loader deliberately computes nothing for a widget that isn't there.
        .task(id: HomeLoadKey(token: session.refresh.token, scope: session.scope, kinds: store.mountedKinds)) {
            await load()
        }
        .onChange(of: navigation?.pendingAdd) { _, _ in
            if navigation?.consumeAdd(.home) == true { isPickingWidget = true }
        }
    }

    /// The way out of edit mode. It borrows the banner's accessory slot
    /// because that is this screen's chrome now — tapping the surface around
    /// the widgets also finishes, but that is not discoverable on its own.
    @ViewBuilder
    private var doneButton: some View {
        if isEditing {
            Button("Done") {
                withAnimation(.snappy(duration: 0.24)) { isEditing = false }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.22), in: Capsule())
            .buttonStyle(.plain)
        }
    }

    /// A scope with nothing behind it takes the whole canvas — an empty
    /// dashboard under a Household banner should say "you have no
    /// household", not draw six widgets all reading "—".
    @ViewBuilder
    private var content: some View {
        if let emptiness = scopeContext?.emptiness(for: session.scope) {
            ScopeEmptyStateView(emptiness: emptiness, session: session)
        } else {
            DashboardCanvasView(
                session: session, store: store, data: data, isLoading: isLoading,
                isEditing: $isEditing, isPickingWidget: $isPickingWidget
            )
        }
    }

    /// One read for the whole dashboard. Widget figures come back as a
    /// single `DashboardData` value — see `DashboardDataLoader` for why this
    /// is one query rather than one per widget.
    private func load() async {
        errorMessage = nil
        guard let baseCurrency = session.profile?.baseCurrency else {
            isLoading = false
            return
        }
        do {
            data = try await DashboardDataLoader.load(
                dbQueue: session.dbQueue, scope: session.scope, baseCurrency: baseCurrency,
                kinds: store.mountedKinds
            )
        } catch {
            // A cancelled load is not a failure — the task id changed and a
            // fresh load is already running. Same shape as `HouseholdView`'s
            // own `isOffline` check: the caller knows which errors are worth
            // a red line and which are not.
            errorMessage = UserFacingError.isCancellation(error) ? nil : UserFacingError.describe(error)
        }
        isLoading = false
    }
}

/// `.task(id:)` needs an `Equatable` id — bundles the refresh token, the
/// scope, and the mounted widget kinds so any of the three changing triggers
/// exactly one reload.
private struct HomeLoadKey: Equatable {
    let token: Int
    let scope: PublicSchema.AccountScope
    let kinds: Set<DashboardWidgetKind>
}
