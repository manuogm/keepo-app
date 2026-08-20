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
    @State private var drag: DashboardDragState?
    @State private var isPickingWidget = false

    /// The drag reads its location in this space, so a finger position
    /// converts straight to a grid cell with no offset arithmetic between.
    private static let gridSpace = "dashboardGrid"

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
            .scrollDisabled(drag != nil)
        }
        .sheet(isPresented: $isPickingWidget) {
            DashboardCatalogView { kind in add(kind) }
        }
    }

    private var horizontalInset: CGFloat { 16 }

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

    private var layout: DashboardResolvedLayout {
        store.arrangement.resolved(expansion: expansion)
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
        .jiggling(isEditing && !isDragging, seed: resolved.id)
        .overlay(alignment: .topTrailing) {
            if isEditing {
                WidgetRemoveBadge { remove(resolved.id) }
                    .offset(x: 8, y: -8)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        // A lifted tile floats above its neighbours and follows the finger.
        .scaleEffect(isDragging ? 1.06 : 1)
        .shadow(color: .black.opacity(isDragging ? 0.22 : 0), radius: 16, y: 8)
        .offset(isDragging ? (drag?.translation).map { CGSize(width: $0.width, height: $0.height) } ?? .zero : .zero)
        .zIndex(isDragging ? 10 : 0)
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
                drag = DashboardDragState(
                    id: tile.id, translation: movement.translation, location: movement.location
                )
            }
            .onEnded { value in
                guard case .second(true, let movement?) = value else {
                    drag = nil
                    return
                }
                drop(tile.id, at: movement.location, geometry: geometry)
            }
    }

    private func drop(_ id: UUID, at location: CGPoint, geometry: DashboardGeometry) {
        let cell = geometry.cell(at: location)
        // The move lands in the same transaction that releases the lift, so
        // the tile animates from where the finger left it to where it
        // belongs, instead of snapping home first and then sliding.
        withAnimation(.snappy(duration: 0.3)) {
            store.move(id: id, toRow: cell.row, column: cell.column)
            drag = nil
        }
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

    private func beginEditing() {
        guard !isEditing else { return }
        withAnimation(.snappy(duration: 0.28)) {
            isEditing = true
            // Everything compacts on the way in, so the arrangement you drag
            // is the arrangement you keep.
            expandedId = nil
            expansionStep = 0
        }
    }

    private func endEditing() {
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
    }

    /// A widget picked from the catalogue drops the user straight into edit
    /// mode with it already on the grid — it lands in the first free slot,
    /// which is rarely where they want it, and this is the one moment they
    /// definitely want to move something.
    private func add(_ kind: DashboardWidgetKind) {
        withAnimation(.snappy(duration: 0.3)) {
            store.append(kind: kind)
            isEditing = true
            expandedId = nil
            expansionStep = 0
        }
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
