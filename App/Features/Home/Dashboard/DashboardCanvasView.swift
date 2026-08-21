import KeepoCore
import SwiftUI

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
    @State var autoScrollDirection: CGFloat = 0
    @State var autoScrollTask: Task<Void, Never>?
    @State var editModeTimeoutTask: Task<Void, Never>?
    /// The widget being dragged out of the catalogue, if any.
    @State var incoming: DashboardIncomingWidget?

    /// The drag reads its location in this space, so a finger position
    /// converts straight to a grid cell with no offset arithmetic between.
    /// Shared with the catalogue, whose drag-out reads the identical space.
    private static let gridSpace = DashboardGridSpace.name

    var body: some View {
        GeometryReader { proxy in
            let geometry = DashboardGeometry(availableWidth: proxy.size.width - horizontalInset * 2)
            ScrollView {
                if store.arrangement.isEmpty && !isLoading {
                    DashboardBlankState { isPickingWidget = true }
                        .frame(height: max(proxy.size.height - 40, 260))
                } else {
                    grid(geometry)
                }
            }
            // A drag in progress must never also scroll the page under it.
            // The gesture below already requires a long press first (which a
            // scroll pan can't satisfy); this closes the remaining case.
            //
            // Programmatic scrolling still works while disabled, which is
            // what edge auto-scroll relies on — the *user* can't pan mid-drag,
            // but the drag itself can move the view.
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
            .overlay { catalogueBackdrop }
            .overlay(alignment: .bottom) { cataloguePanel(geometry, viewportHeight: proxy.size.height) }
            .animation(.snappy(duration: 0.3), value: isPickingWidget)
        }
    }

    private var horizontalInset: CGFloat { 16 }

    /// A lifted tile grows; every other tile shrinks while editing.
    private func editModeScale(isDragging: Bool) -> CGFloat {
        if isDragging { return 1.06 }
        return isEditing ? 0.92 : 1
    }

    private func grid(_ geometry: DashboardGeometry) -> some View {
        VStack(spacing: geometry.spacing) {
            DashboardGridView(layout: layout, geometry: geometry) { resolved in
                tile(resolved, geometry: geometry)
            }
            .coordinateSpace(name: Self.gridSpace)

            HStack(spacing: geometry.spacing) {
                AddWidgetTile { isPickingWidget = true }
                    .frame(width: geometry.cellSize, height: geometry.cellSize)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, horizontalInset)
        .padding(.top, 4)
        .padding(.bottom, 24)
        .animation(.snappy(duration: 0.32), value: layout)
        // Tapping the surface around the widgets leaves edit mode — the same
        // "tap the wallpaper to finish" the home screen offers, so Done in
        // the toolbar isn't the only way out.
        .contentShape(Rectangle())
        .onTapGesture { if isEditing { endEditing() } }
    }

    // MARK: - Layout

    /// While a drag is live this resolves the *preview* arrangement, so every
    /// other tile is already sitting where the drop would put it. The dragged
    /// tile itself is drawn under the finger instead (see `tile`), not at its
    /// preview position — otherwise it would fight the finger for the same
    /// pixels.
    private var layout: DashboardResolvedLayout {
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

    private func tile(_ resolved: DashboardResolvedTile, geometry: DashboardGeometry) -> some View {
        let isDragging = drag?.id == resolved.id
        return DashboardWidgetView(
            kind: resolved.kind,
            data: data,
            expansionStep: expandedId == resolved.id && !isEditing ? expansionStep : nil,
            onExpand: { step in setExpansion(resolved, step: step) },
            loadSeries: loadNetWorthSeries,
            loadFxTrend: loadFxTrend,
            loadCashflow: loadCashflow,
            loadRatioHistory: loadRatioHistory
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
        .onLongPressGesture(minimumDuration: 0.45) { beginEditing() }
        .gesture(isEditing ? pressAndDrag(resolved, geometry: geometry) : nil)
    }

    // MARK: - Gestures

    /// Edit mode's drag. The short press in front of it is what separates
    /// "pick this tile up" from "flick the list" once scrolling and dragging
    /// are both live on the same surface.
    private func pressAndDrag(_ tile: DashboardResolvedTile, geometry: DashboardGeometry) -> some Gesture {
        LongPressGesture(minimumDuration: 0.12)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.gridSpace)))
            .onChanged { value in
                guard case .second(true, let movement?) = value else { return }
                // The grab offset is measured once, against the tile's
                // position before anything reflowed — recomputing it each
                // frame would chase the preview and drift.
                let grabOffset = drag?.grabOffset ?? grabOffset(
                    for: tile, startLocation: movement.startLocation, geometry: geometry
                )
                drag = DashboardDragState(
                    id: tile.id, location: movement.location, grabOffset: grabOffset
                )
                updatePreview(for: tile.id, at: movement.location, geometry: geometry)
                updateAutoScroll(gridY: movement.location.y, geometry: geometry)
            }
            .onEnded { value in
                guard case .second(true, let movement?) = value else {
                    clearDrag()
                    return
                }
                drop(tile.id, at: movement.location, geometry: geometry)
            }
    }

    private func grabOffset(
        for tile: DashboardResolvedTile, startLocation: CGPoint, geometry: DashboardGeometry
    ) -> CGSize {
        let origin = geometry.origin(row: tile.row, column: tile.column)
        return CGSize(width: startLocation.x - origin.x, height: startLocation.y - origin.y)
    }

    /// How far to shift the dragged tile from wherever the layout has just
    /// put it, so it stays pinned under the finger.
    private func dragOffset(for tile: DashboardResolvedTile, geometry: DashboardGeometry) -> CGSize {
        guard let drag, drag.id == tile.id else { return .zero }
        let origin = geometry.origin(row: tile.row, column: tile.column)
        return CGSize(
            width: drag.location.x - drag.grabOffset.width - origin.x,
            height: drag.location.y - drag.grabOffset.height - origin.y
        )
    }

    /// Rebuilds the would-be arrangement as the finger moves, but only when
    /// the finger crosses into a different cell — rebuilding per frame would
    /// restart the reflow animation on every touch event and leave the grid
    /// permanently mid-transition.
    func updatePreview(for id: UUID, at location: CGPoint, geometry: DashboardGeometry) {
        let cell = geometry.cell(at: location)
        guard cell != previewCell else { return }
        previewCell = cell

        var preview = store.arrangement
        preview.move(id: id, toRow: cell.row, column: cell.column)
        withAnimation(.snappy(duration: 0.25)) { dragPreview = preview }
    }

    private func drop(_ id: UUID, at location: CGPoint, geometry: DashboardGeometry) {
        let cell = geometry.cell(at: location)
        // Everything on screen is already in its final position — the preview
        // put it there while the finger was still down. This only makes it
        // real and drops the tile back into the grid from under the finger.
        withAnimation(.snappy(duration: 0.3)) {
            store.move(id: id, toRow: cell.row, column: cell.column)
            clearDrag()
        }
        bumpEditModeTimeout()
    }

    private func clearDrag() {
        stopAutoScroll()
        drag = nil
        dragPreview = nil
        previewCell = nil
    }

    /// The widget asks for the size it wants — `nil` to collapse, otherwise
    /// an index into its own `expandedSizes`. Deliberately not a blind
    /// "cycle to the next size": Cashflow's second size only means anything
    /// with a direction selected, so cycling into it from a plain tap would
    /// open a state the widget has nothing to draw in. Each widget knows its
    /// own steps; the canvas only enforces that one tile is open at a time.
    ///
    /// In edit mode this does nothing — the tile is being arranged, not read.
    private func setExpansion(_ tile: DashboardResolvedTile, step: Int?) {
        guard !isEditing else { return }
        withAnimation(.snappy(duration: 0.32)) {
            guard let step, step >= 0, step < tile.kind.expandedSizes.count else {
                expandedId = nil
                expansionStep = 0
                return
            }
            expandedId = tile.id
            expansionStep = step
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

    /// Same window as the collapsed trend lines, so a rate chart and a net
    /// worth chart opened side by side cover the same stretch of time.
    private func loadFxTrend(_ currency: String) async -> [DashboardSeriesPoint]? {
        guard let baseCurrency = session.profile?.baseCurrency else { return nil }
        let today = Date()
        let from = utcCalendar.date(
            byAdding: .day, value: -(DashboardDataLoader.trendRangeDays - 1), to: today
        ) ?? today
        return try? await DashboardDataLoader.fxTrend(
            dbQueue: session.dbQueue, currency: currency, baseCurrency: baseCurrency,
            from: from, through: today
        )
    }

    private func loadCashflow(_ period: CashflowPeriod) async -> CashflowMetrics? {
        guard let baseCurrency = session.profile?.baseCurrency else { return nil }
        return try? await DashboardDataLoader.cashflow(
            dbQueue: session.dbQueue, scope: session.scope, baseCurrency: baseCurrency, period: period
        )
    }

    private func loadRatioHistory() async -> [InvestingRatioPoint]? {
        guard let baseCurrency = session.profile?.baseCurrency else { return nil }
        return try? await DashboardDataLoader.investingRatioHistory(
            dbQueue: session.dbQueue, scope: session.scope, baseCurrency: baseCurrency
        )
    }

    private func loadNetWorthSeries(from: Date, through: Date) async -> [DashboardSeriesPoint]? {
        guard let baseCurrency = session.profile?.baseCurrency else { return nil }
        return try? await DashboardDataLoader.netWorthSeries(
            dbQueue: session.dbQueue, scope: session.scope, baseCurrency: baseCurrency,
            from: from, through: through
        )
    }
}
