import KeepoCore
import SwiftUI

/// The Needs Review inbox, as a drawer that drops out from underneath the
/// scope banner on the Transactions screen.
///
/// It used to be a bell in Home's toolbar opening a floating panel, and
/// that was wrong twice over: the items are transactions, so Home was the
/// wrong screen for them, and a circular icon button with a red dot said
/// "a number of things" without ever saying what. This says what — "3 items
/// need review" — in the place those items will be edited.
///
/// **Why it is drawn the way it is.** The drawer is exactly as wide as the
/// banner and is pulled *up* behind it by its own corner radius, so its top
/// edge is hidden and only its rounded bottom shows: it reads as something
/// that came out from under the banner rather than as a second card parked
/// below one. It owns no top corners for that reason. Collapsed it is one
/// row; **expanded it takes the whole screen** below the banner, because an
/// inbox you are working through is the screen, not a strip above one. It
/// renders nothing at all when the inbox is empty, so a healthy account
/// never pays for it in vertical space — and because it hides behind the
/// banner, nothing has to move when it appears.
///
/// **Expanded, it is the ledger.** A `List` of real `TransactionRow`s with
/// the ledger's own swipe gestures, not a bespoke stack of panel rows — so
/// an item here looks and behaves like the transaction it is about to
/// become, and confirming one is the same gesture as confirming one on the
/// screen underneath. Clearing a row animates it out of the list, because
/// the whole point of an inbox is watching it get shorter.
///
/// Clearing the last item does not simply make it vanish: the drawer says
/// so, holds the moment, and then closes itself back onto the ledger. An
/// inbox that emptied silently gave no acknowledgement that the work was
/// finished, only a screen that had stopped being there.
///
/// One renderer switching on `item.kind` — `needs_review`'s stable column
/// contract means a later phase's new branch needs no change here at all,
/// only a new `case` in the icon/action switches.
struct NeedsReviewPanel: View {
    let session: SessionStore
    /// Owned by the screen, not here: expanding hides the ledger, and the
    /// drawer cannot hide a sibling it does not own.
    @Binding var isExpanded: Bool

    @State var items: [NeedsReviewItem] = []
    @State var currencyMinorUnits: [String: Int] = [:]
    @State var actionError: ActionError?
    @State var editingTransaction: PublicSchema.TransactionsWithDetailsSelect?
    @State var mappingCard: PublicSchema.NeedsReviewSelect?
    @State var showCardMapping = false
    @State var conflictId: UUID?
    /// Bumped once per item cleared, purely so the haptic has something to
    /// fire on. `items.count` cannot serve: it also moves on every reload.
    @State var resolvedCount = 0
    /// Held on screen for a beat after the last item goes, then closes the
    /// drawer. Also what keeps the drawer rendered at all past that point —
    /// see `isVisible`. Internal, not `private`, for the same reason
    /// `Metrics` is: `private` is file-scoped, and the chrome that draws
    /// this lives next door.
    @State var showSuccess = false

    /// Optional so a preview never has to install one.
    @Environment(FTUXCoordinator.self) private var ftux: FTUXCoordinator?

    enum Metrics {
        /// The drawer's bottom radius, and equally the distance it hides
        /// behind the banner — the two are the same number because the
        /// hidden part *is* the top corners nobody should see. One token, so
        /// the drawer's corner can never drift away from the sheets and
        /// widgets it sits among.
        static let radius = AppTheme.Radius.surface

        /// How long the cleared state stays up before the drawer closes
        /// itself. `ConfettiBurst` runs for 1.6s, so this is that plus a
        /// beat of stillness — closing mid-burst reads as an interruption
        /// rather than as an ending.
        static let successHold = Duration.seconds(2.2)

        /// The gap between the two beats of the close — see `body`'s
        /// `onChange`. Matched to `Motion.standard`'s own 0.25s, so the
        /// second beat starts as the first is settling and the two read as
        /// one continuous movement rather than as a pause between them.
        static let contract = Duration.seconds(0.25)

        /// The gap between two item tiles. Split in half above and below
        /// each one, so the first tile sits the same distance under the
        /// header as the tiles do from each other.
        static let tileGutter = AppTheme.Spacing.s

    }

    var body: some View {
        // A `VStack`, not a `Group` resolving to `EmptyView`: modifiers on
        // an empty branch are not reliably honoured, and the `.task` below
        // is what fills `items` in the first place — so the panel that
        // renders nothing until it has items must not be the thing deciding
        // whether the load runs.
        VStack(spacing: 0) {
            if isVisible {
                panel
                    // Attached to the panel, not the screen: the lesson is
                    // "this thing here is the inbox", and the panel only
                    // exists when there is something to explain.
                    .ftuxAnchor(FTUXLessons.needsReview)
            }
        }
        .frame(maxHeight: isExpanded ? .infinity : nil)
        .task(id: session.refresh.token) { await load() }
        // Offered from here rather than from the screen, because whether
        // there *is* an inbox to point at is this view's own answer — and
        // the coordinator sorts what it is offered, so arriving after the
        // ledger's own lesson does not put this one first.
        .task(id: isVisible) {
            guard isVisible else { return }
            await ftux?.offer([FTUXLessons.needsReview])
        }
        // **The close is the opening run backwards, in two beats.**
        // Expanding grew the drawer out of a one-row header and into the
        // whole screen; closing has to undo exactly that, or the drawer
        // simply stops being there. So it first *contracts* out of the
        // screen it had taken — uncovering the ledger underneath it as it
        // shrinks — and only then tucks back up behind the banner it came
        // out of. Doing both at once slid a full-screen surface off the top
        // of the display, which is so much travel that it read as a fade.
        .onChange(of: items.isEmpty) { _, isEmpty in
            guard isEmpty, isExpanded else { return }
            withAnimation(AppTheme.Motion.standard) { showSuccess = true }
            Task {
                try? await Task.sleep(for: Metrics.successHold)
                withAnimation(AppTheme.Motion.standard) { isExpanded = false }
                try? await Task.sleep(for: Metrics.contract)
                withAnimation(AppTheme.Motion.standard) { showSuccess = false }
            }
        }
        // A row leaving reports itself as a landing, not as a success: the
        // success rhythm is saved for the cleared state below, so working
        // through a full inbox builds to it instead of repeating it.
        .sensoryFeedback(AppTheme.Feedback.drop, trigger: resolvedCount)
        .sensoryFeedback(trigger: showSuccess) { _, isShowing in
            isShowing ? AppTheme.Feedback.success : nil
        }
        .errorAlert($actionError)
        .sheet(item: $editingTransaction) { transaction in
            TransactionFormView(session: session, mode: .edit(transaction, sibling: nil)) {
                session.refresh.bump()
            }
        }
        .sheet(isPresented: $showCardMapping) {
            if let mappingCard {
                MapCardSheet(session: session, item: mappingCard) {
                    session.refresh.bump()
                }
            }
        }
        .sheet(item: $conflictId) { id in
            ConflictDetailSheet(session: session, conflictId: id) {
                session.refresh.bump()
            }
        }
    }

    /// Rendered while there is anything to say — items to review, or the
    /// fact that there are no longer any.
    private var isVisible: Bool { !items.isEmpty || showSuccess }

    private var panel: some View {
        VStack(spacing: 0) {
            // The strip that lives behind the banner. Flat, no corners, no
            // content — it exists so the drawer has something to be pulled
            // out of.
            Color.clear.frame(height: Metrics.radius)

            if showSuccess {
                successState
            } else {
                header
                if isExpanded {
                    // No rule between the header and the list: the items are
                    // tiles now, and a divider inset to line up with rows
                    // that no longer exist was pointing at nothing.
                    itemList
                }
            }
        }
        .background(surface)
        // **`compositingGroup` before the shadow, not after.** SwiftUI's
        // `.shadow` is a drawing modifier that descends into the subtree:
        // without this it is applied to every child *individually*, so each
        // item tile drew its own halo onto the drawer's own surface and
        // a swiped row looked like it was lifting off a second white card.
        // Flattening first makes the shadow come from the drawer's own
        // silhouette, which is the only thing that is supposed to be
        // floating here.
        .compositingGroup()
        .elevation(.resting)
        .padding(.top, -Metrics.radius)
        .frame(maxHeight: isExpanded ? .infinity : nil, alignment: .top)
        .animation(AppTheme.Motion.standard, value: isExpanded)
        .animation(AppTheme.Motion.standard, value: items.count)
        // Asymmetric, because arriving and leaving are not the same
        // event. It fades in as it drops out from under the banner; it
        // leaves by moving alone, with no fade, so the last thing the eye
        // sees is the drawer going *behind* the banner rather than
        // dissolving in front of it.
        .transition(.asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .move(edge: .top)
        ))
    }

    /// Takes the rest of the screen, because expanding is the user saying
    /// they are here to work through the list.
    ///
    /// A `List`, like the ledger, and for the ledger's reasons: the swipe
    /// gestures are the app's established vocabulary for confirming and
    /// deleting a transaction (there is a coach mark teaching them one
    /// screen down), and a `List` animates a removed row out on its own —
    /// which is exactly what clearing an item should look like. The panel's
    /// own surface stays the drawer's, so the rows sit *in* the drawer
    /// rather than on tiles inside it.
    private var itemList: some View {
        List {
            ForEach(items) { entry in
                // A `Button`, not `.onTapGesture`, for the same reason the
                // ledger uses one: a bare tap gesture inside a `List` loses
                // races with the scroll recogniser and draws no press state.
                Button {
                    open(entry.item)
                } label: {
                    NeedsReviewRow(entry: entry, minorUnit: minorUnit(for: entry.item.currency))
                        // The tile's own inner inset. `l` horizontally so a
                        // category icon in here lands exactly where one does
                        // in a ledger tile on the screen underneath.
                        .padding(.horizontal, AppTheme.Spacing.l)
                        .padding(.vertical, AppTheme.Spacing.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // **The tile is the row's own background, not
                        // `listRowBackground`.** That modifier paints the
                        // cell *behind* the content, and a swiped row slides
                        // its content off that cell — so the tile stayed
                        // put, the plain white cell underneath came out from
                        // behind it, and every swipe flashed a white
                        // rectangle around the tile. Drawn here it is part
                        // of the row, so it travels with it and the drawer's
                        // own surface is the only thing behind the gesture.
                        .background(
                            AppTheme.Palette.bgSurface,
                            in: RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                        )
                }
                .buttonStyle(.pressableRow)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(
                    top: Metrics.tileGutter / 2, leading: AppTheme.Spacing.l,
                    bottom: Metrics.tileGutter / 2, trailing: AppTheme.Spacing.l
                ))
                // Nothing to separate: each item is its own tile, and a
                // hairline between two things that are already apart is
                // the kind of line that only says "this used to be a list".
                .listRowSeparator(.hidden)
                // **One direction per answer.** Right to keep it, left to
                // get rid of it: an inbox is a yes/no pile, and putting both
                // answers behind one swipe made the user stop and read two
                // buttons to give an answer their thumb already knew. Full
                // swipe is on by default at each edge, so either verdict can
                // be given without ever lifting off.
                //
                // A `Label`, not a bare `Image`, and that is the whole
                // difference: given both a title and a symbol, the system
                // draws the glyph in a coloured capsule with the word as a
                // small grey caption *under* it — exactly what the ledger's
                // own swipe-to-delete looks like one screen down. A bare
                // image gets the capsule and no caption, which left the
                // gesture's meaning to be guessed.
                //
                // **The system's red and green, not the palette's.** This is
                // the one place in the app where matching iOS beats matching
                // Keepo: the ledger's own swipe-to-delete is drawn by UIKit
                // from `.onDelete` in the system red, it sits one screen
                // down, and the two are compared directly. A palette red
                // that is nearly but not quite that colour reads as a
                // mistake. Both tints are stated rather than left to
                // `role: .destructive`, because `MainTabView` sets an
                // app-wide `.tint` that beats the role's own colour.
                .swipeActions(edge: .leading) {
                    if let quick = quickAction(entry) {
                        Button { perform(quick.kind, on: entry.item) } label: {
                            Label(quick.title, systemImage: quick.symbol)
                        }
                        .tint(.green)
                    }
                }
                .swipeActions(edge: .trailing) {
                    if let destructive = destructiveAction(entry.item) {
                        Button(role: .destructive) {
                            perform(destructive.kind, on: entry.item)
                        } label: {
                            Label(destructive.title, systemImage: destructive.symbol)
                        }
                        .tint(.red)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .contentMargins(.bottom, KeepoTabBarMetrics.clearance, for: .scrollContent)
        .frame(maxHeight: .infinity)
        // The rows only, not the drawer: expanded, this reaches the bottom
        // of the display like the ledger it replaces, so it needs the same
        // fade under the tab bar — but masking the whole drawer would
        // dissolve its own surface along with them. There is nothing to
        // fade at the top; the drawer's header is above this.
        .fadingEdges(top: 0)
        .transition(.opacity)
    }

    func minorUnit(for currencyCode: String?) -> Int {
        guard let currencyCode else { return 2 }
        return currencyMinorUnits[currencyCode] ?? 2
    }
}
