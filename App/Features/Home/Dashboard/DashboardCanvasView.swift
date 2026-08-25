import KeepoCore
import SwiftUI
import UniformTypeIdentifiers

/// The dashboard itself — the grid, what each tile contains, which one is
/// expanded, and edit mode. Split from `HomeView`, which keeps the screen's
/// chrome (the scope menu, the notifications bell, the title bar) exactly as
/// it was; the dashboard replaced Home's *body*, not Home.
///
/// Expansion and the drag both live here rather than in `DashboardStore`
/// because neither is part of the user's arrangement: they are transient view
/// state that must not survive a relaunch, and
/// `DashboardArrangement.resolved(expansion:)` deliberately never mutates the
/// stored layout to produce them.
struct DashboardCanvasView: View {
    let session: SessionStore
    let store: DashboardStore
    let data: DashboardData
    let isLoading: Bool
    @Binding var isEditing: Bool

    @State private var expandedId: UUID?
    /// Which of the expanded tile's sizes is showing. Only Cashflow has more
    /// than one, but the cycle is uniform: base → first → … → back to base.
    @State private var expansionStep = 0
    @State var drag: DashboardDragState?
    /// The arrangement as it *would* be if the finger let go right now.
    ///
    /// Held here rather than written to `DashboardStore` on every frame:
    /// `DashboardArrangement.move` is pure, so the reflowed layout is free to
    /// compute and free to throw away, and the store — which persists to disk
    /// on every mutation — is only touched once, on drop.
    @State var dragPreview: DashboardArrangement?
    /// The cell the preview was last built for, so a finger moving *within*
    /// one cell doesn't rebuild and re-animate the whole grid.
    @State var previewCell: DashboardGridCell?
    @State var isPickingWidget = false
    // Not `private`: `DashboardAutoScroll.swift` extends this type, and a
    // `private` member is invisible to its own type's extension in a
    // different file.
    @State var scrollPosition = ScrollPosition()
    @State var scrollGeometry = DashboardScrollGeometry()
    @State var autoScrollVelocity: CGFloat = 0
    @State var autoScrollTask: Task<Void, Never>?
    @State var editModeTimeoutTask: Task<Void, Never>?
    /// The widget being dragged out of the catalogue, if any.
    @State var incoming: DashboardIncomingWidget?
    /// The grid's frame inside the canvas — the one number that turns a
    /// drop location into a grid location.
    @State var gridFrame: CGRect = .zero
    /// Which widget the catalogue last handed to a drag session, waiting to
    /// be claimed when that drag reaches the dashboard.
    @State var liftedKind: DashboardWidgetKind?
    /// Where an arriving widget last was, in canvas space — the one thing
    /// edge auto-scroll needs to re-resolve its landing cell after moving
    /// the grid out from under a finger that is holding still.
    @State var lastDropPoint: CGPoint?
    /// The trash bar's frame inside the canvas, measured for the same
    /// reason `gridFrame` is: the drop delegate reports canvas points, and
    /// "is the finger over the trash" has to be asked in that space.
    @State var trashFrame: CGRect = .zero
    /// Whether letting go right now would throw the arriving widget away.
    @State var isOverTrash = false
    /// The recurring rule the Upcoming widget asked to open. Not `private`:
    /// `DashboardCanvasLoading.swift` extends this type, and a `private`
    /// member is invisible to its own type's extension in a different file.
    @State var editingRule: PublicSchema.RecurringRulesSelect?

    /// The catalogue is a **sibling** of the dashboard's scroll view, not an
    /// overlay on it, and that is not a layout preference.
    ///
    /// As an overlay the panel sits inside the scroll view's own gesture
    /// territory: its enclosing `UIScrollView` sees every touch that lands
    /// on the panel and claims the pan, so the catalogue's list would not
    /// scroll at all — and worst of all it looked like a gesture-priority
    /// problem inside the catalogue, which is where the previous two fixes
    /// went. A `ZStack` puts the panel beside the scroll view instead, out
    /// of reach of a recognizer that was never meant to see it.
    var body: some View {
        GeometryReader { proxy in
            let geometry = DashboardGeometry(availableWidth: proxy.size.width - horizontalInset * 2)
            ZStack(alignment: .bottom) {
                ScrollView {
                    // `incoming`, because a widget on its way in needs the
                    // grid to reflow around and the trash bar to be thrown
                    // at — neither of which the blank state has. A first
                    // widget dragged onto an empty dashboard otherwise
                    // travelled over a screen with nothing on it.
                    if store.arrangement.isEmpty && incoming == nil && !isLoading {
                        DashboardBlankState { isPickingWidget = true }
                            .frame(height: max(proxy.size.height - 40, 260))
                    } else {
                        grid(geometry)
                    }
                }
                // A drag in progress must never also scroll the page under
                // it. The tile gesture already requires a brief press first
                // (which a scroll pan can't satisfy); this closes the
                // remaining case.
                //
                // Programmatic scrolling still works while disabled, which is
                // what edge auto-scroll relies on — the *user* can't pan
                // mid-drag, but the drag itself can move the view.
                .scrollDisabled(drag != nil)
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: DashboardScrollGeometry.self) { proxy in
                    DashboardScrollGeometry(
                        offsetY: proxy.contentOffset.y,
                        viewportHeight: proxy.containerSize.height,
                        contentHeight: proxy.contentSize.height
                    )
                } action: { _, updated in
                    scrollGeometry = updated
                }

                catalogueBackdrop
                cataloguePanel(geometry, viewportHeight: proxy.size.height)
            }
            .coordinateSpace(name: DashboardSpace.canvas)
            .sheet(item: $editingRule) { rule in
                RecurringRuleFormView(session: session, mode: .edit(rule)) {
                    session.refresh.bump()
                }
            }
            .onDrop(of: [.plainText], delegate: widgetDrop(geometry))
            .animation(.snappy(duration: 0.3), value: isPickingWidget)
            .modifier(DashboardHaptics(
                isEditing: isEditing, carriedId: incoming?.id, draggedId: drag?.id,
                targetCell: previewCell, isOverTrash: isOverTrash, arrangement: store.arrangement
            ))
        }
    }

    private var horizontalInset: CGFloat { 16 }

    /// A lifted tile grows; every other tile shrinks while editing.
    ///
    /// Both numbers are small on purpose. What the eye reads is the
    /// *difference* between the tile in hand and the ones around it, so a
    /// 4% lift over a 6% shrink already says "this one is off the surface" —
    /// anything more and the tile balloons out of its own slot and stops
    /// looking like the thing about to be dropped into it.
    private func editModeScale(isDragging: Bool) -> CGFloat {
        if isDragging { return 1.04 }
        return isEditing ? 0.94 : 1
    }

    private func grid(_ geometry: DashboardGeometry) -> some View {
        VStack(spacing: geometry.spacing) {
            DashboardGridView(layout: layout, geometry: geometry) { resolved in
                tile(resolved, geometry: geometry)
            }
            .coordinateSpace(name: DashboardSpace.grid)
            // Where the grid sits inside the canvas, which is where the
            // drop target reports its locations. Measured rather than
            // derived — see `gridPoint(_:)`.
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(DashboardSpace.canvas))
            } action: { frame in
                gridFrame = frame
            }

            bottomSlot(geometry)
                .padding(.top, carriedReserve(geometry))
        }
        .padding(.horizontal, horizontalInset)
        .padding(.top, 4)
        .padding(.bottom, 24)
        .animation(.snappy(duration: 0.32), value: layout)
        // Tapping the surface around the widgets leaves edit mode — the same
        // "tap the wallpaper to finish" the home screen offers, so Done in
        // the toolbar isn't the only way out — and closes an expanded
        // widget, which is the "or outside it" half of how a widget
        // collapses.
        .contentShape(Rectangle())
        .onTapGesture {
            if isEditing {
                endEditing()
            } else {
                collapseExpanded()
            }
        }
    }

    // MARK: - Layout

    /// While a drag is live this resolves the *preview* arrangement, so every
    /// other tile is already sitting where the drop would put it. The dragged
    /// tile itself is drawn under the finger instead (see `tile`), not at its
    /// preview position — otherwise it would fight the finger for the same
    /// pixels.
    ///
    /// Not `private`, for the same reason the state above isn't: this type's
    /// extensions live in other files, and `carriedReserve` reads it.
    var layout: DashboardResolvedLayout {
        (dragPreview ?? store.arrangement).resolved(expansion: expansion)
    }

    /// Edit mode compacts everything, per the design — you arrange tiles at
    /// the size they rest at, never at the size one of them happened to be
    /// expanded to.
    private var expansion: DashboardExpansion? {
        guard !isEditing, let expandedId, let tile = store.arrangement.tile(id: expandedId) else { return nil }
        let sizes = tile.kind.expandedSizes
        guard expansionStep < sizes.count else { return nil }
        return DashboardExpansion(id: expandedId, size: sizes[expansionStep])
    }

    // MARK: - Tiles

    @ViewBuilder
    private func tile(_ resolved: DashboardResolvedTile, geometry: DashboardGeometry) -> some View {
        if incoming?.id == resolved.id {
            // Not a widget yet — the grid has reflowed around where one is
            // about to go, and the widget itself is in the user's hand.
            //
            // Faded rather than removed while the finger is over the trash.
            // The slot is a promise about where the widget lands, and over
            // the trash that promise is off — but taking it out of the
            // layout would shorten the grid and move the trash bar itself
            // (see `previewIncoming`), so it dims in place instead.
            DashboardLandingSlot()
                .opacity(isOverTrash ? 0.3 : 1)
                .animation(.easeInOut(duration: 0.18), value: isOverTrash)
        } else {
            placedTile(resolved, geometry: geometry)
        }
    }

    private func placedTile(_ resolved: DashboardResolvedTile, geometry: DashboardGeometry) -> some View {
        let isDragging = drag?.id == resolved.id
        return DashboardWidgetView(
            kind: resolved.kind,
            data: data,
            expansionStep: expandedId == resolved.id && !isEditing ? expansionStep : nil,
            onExpand: { step in setExpansion(resolved, step: step, geometry: geometry) },
            seriesContext: seriesContext,
            loadBreakdown: loadBreakdown,
            openRule: openRule
        )
        .redacted(reason: isLoading ? .placeholder : [])
        // The badge is inside `.jiggling`, not layered on after it, so it
        // rocks with the tile instead of hovering stationary over a moving
        // card — which read as a bug, not a decoration.
        .overlay(alignment: .topTrailing) {
            if isEditing {
                WidgetRemoveBadge { remove(resolved.id) }
                    .offset(x: 8, y: -8)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .jiggling(isEditing && !isDragging, seed: resolved.id)
        // Edit mode shrinks every tile slightly. Not decoration: it widens
        // the gutters between tiles and against the screen edge, which are
        // the only places a finger can start a scroll while the drag gesture
        // owns the tiles themselves. At full size those gutters are 12pt and
        // genuinely hard to hit.
        .scaleEffect(editModeScale(isDragging: isDragging))
        .shadow(color: .black.opacity(isDragging ? 0.22 : 0), radius: 16, y: 8)
        .offset(isDragging ? dragOffset(for: resolved, geometry: geometry) : .zero)
        .zIndex(isDragging ? 10 : 0)
        // The lifted tile opts out of the reflow animation the other tiles
        // are running. Its laid-out origin jumps the instant the preview
        // moves it, and its offset compensates by exactly that much — but
        // only one of the two is inside the animation, so animating either
        // makes it visibly lurch away from the finger and swim back. It has
        // to track the finger frame-for-frame; everything else animates.
        .transaction { transaction in
            if isDragging { transaction.animation = nil }
        }
        // Two different gestures, deliberately, and this is load-bearing.
        //
        // A `DragGesture` attached with `.gesture` — even sequenced behind a
        // long press — takes the touch away from the enclosing `ScrollView`
        // before either has recognised anything, and the dashboard simply
        // stops scrolling. That shipped for about an hour and was found by
        // bisection, not by reading: nothing about the code says "this
        // disables scrolling".
        //
        // So outside edit mode there is no drag gesture at all, only
        // `.onLongPressGesture`, which coexists with the scroll pan the way
        // every context menu in iOS does. The drag is attached only while
        // editing, where taking the touch is exactly what we want.
        //
        // `.simultaneousGesture`, because the card underneath has a tap
        // gesture of its own (expand/collapse) and a descendant's gesture
        // otherwise takes the touch outright: attached the ordinary way the
        // press never completed at all, and a long hold expanded the widget
        // instead of starting edit mode. Recognising alongside it lets the
        // press through, and the tap that arrives on release is a no-op
        // because `setExpansion` refuses to run in edit mode.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                if !isEditing { beginEditing() }
            }
        )
        .gesture(isEditing ? pressAndDrag(resolved, geometry: geometry) : nil)
    }

    /// The widget asks for the size it wants — `nil` to collapse, otherwise
    /// an index into its own `expandedSizes`. Deliberately not a blind
    /// "cycle to the next size": Cashflow's second size only means anything
    /// with a direction selected, so cycling into it from a plain tap would
    /// open a state the widget has nothing to draw in. Each widget knows its
    /// own steps; the canvas only enforces that one tile is open at a time.
    ///
    /// In edit mode this does nothing — the tile is being arranged, not read.
    private func setExpansion(_ tile: DashboardResolvedTile, step: Int?, geometry: DashboardGeometry) {
        guard !isEditing else { return }
        guard let step, step >= 0, step < tile.kind.expandedSizes.count else {
            withAnimation(.snappy(duration: 0.32)) {
                expandedId = nil
                expansionStep = 0
            }
            return
        }
        let size = tile.kind.expandedSizes[step]
        // Expanding in place can push the tile's bottom past the fold, so the
        // canvas scrolls to it — **in the completion, not in the body**.
        // `scrollTo(y:)` is clamped by the system to the content height as it
        // stands when called, and the tile only makes the content taller as
        // this animation runs; issued in the same turn, the scroll was
        // swallowed exactly where it was needed most — on a dashboard already
        // scrolled near its end.
        withAnimation(.snappy(duration: 0.32)) {
            expandedId = tile.id
            expansionStep = step
        } completion: {
            withAnimation(.snappy(duration: 0.3)) {
                scrollToFit(row: tile.row, size: size, geometry: geometry)
            }
        }
    }

    /// Collapses whatever is expanded. The counterpart to the card's own tap:
    /// the design says a widget closes by tapping its background **or**
    /// outside it, and "outside" is this — the padding around the grid, and
    /// the empty canvas under it.
    private func collapseExpanded() {
        guard expandedId != nil else { return }
        withAnimation(.snappy(duration: 0.32)) {
            expandedId = nil
            expansionStep = 0
        }
    }

    // MARK: - Editing

    func beginEditing() {
        guard !isEditing else { return }
        withAnimation(.snappy(duration: 0.28)) {
            isEditing = true
            // Everything compacts on the way in, so the arrangement you drag
            // is the arrangement you keep.
            expandedId = nil
            expansionStep = 0
        }
        bumpEditModeTimeout()
    }

    private func endEditing() {
        cancelEditModeTimeout()
        withAnimation(.snappy(duration: 0.24)) { isEditing = false }
    }

    private func remove(_ id: UUID) {
        withAnimation(.snappy(duration: 0.3)) {
            store.remove(id: id)
            if expandedId == id {
                expandedId = nil
                expansionStep = 0
            }
            // Removing the last widget leaves nothing to arrange, so edit
            // mode ends with it — otherwise the blank state renders under a
            // "Done" button that has no work left to finish.
            if store.arrangement.isEmpty {
                isEditing = false
            }
        }
        bumpEditModeTimeout()
    }

    /// A widget picked from the catalogue drops the user straight into edit
    /// mode with it already on the grid — it lands in the first free slot,
    /// which is rarely where they want it, and this is the one moment they
    /// definitely want to move something.
    func add(_ kind: DashboardWidgetKind) {
        withAnimation(.snappy(duration: 0.3)) {
            store.append(kind: kind)
            isEditing = true
            expandedId = nil
            expansionStep = 0
        }
        bumpEditModeTimeout()
    }

}
