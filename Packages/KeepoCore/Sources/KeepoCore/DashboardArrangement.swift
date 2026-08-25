import Foundation

/// The dashboard's tiles and every operation that rearranges them. Split
/// from `DashboardLayout.swift` (which holds the vocabulary — sizes, kinds,
/// tiles) so the rules live apart from the nouns they act on; the placement
/// primitives they all share are in `DashboardArrangement+Placement.swift`.
///
/// Every mutation ends in the same two steps — resolve overlaps, then drop
/// fully empty rows — so no sequence of drags, adds, and removals can leave
/// an arrangement this type would refuse to render. That invariant is why
/// `tiles` is `private(set)`: a caller able to write a tile's `row`
/// directly could break it.
public struct DashboardArrangement: Sendable, Equatable, Codable {
    public private(set) var tiles: [DashboardTile]

    /// Always normalizes. Decoding persisted JSON goes through here too, so
    /// a hand-edited or partially-migrated `UserDefaults` payload can't put
    /// overlapping tiles on screen.
    public init(tiles: [DashboardTile] = []) {
        self.tiles = Self.normalized(tiles)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(tiles: try container.decode([DashboardTile].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(tiles)
    }

    public var isEmpty: Bool { tiles.isEmpty }

    /// Rows occupied at rest — the bottom edge of the lowest tile, not the
    /// index it starts at, since a widget is two rows tall. The expanded
    /// height is `resolved(...)`'s job — only it knows what is expanded.
    public var rowCount: Int { tiles.map { $0.row + $0.size.rows }.max() ?? 0 }

    public func tile(id: UUID) -> DashboardTile? { tiles.first { $0.id == id } }

    /// Whether this kind is already on the dashboard.
    ///
    /// Today one of each is the rule, and the catalogue disables a kind that
    /// is already placed. It is enforced there rather than here on purpose:
    /// `id` is per-instance precisely so that two tiles of one kind *can*
    /// coexist, which is what user-built template widgets will need — each
    /// will be its own kind carrying its own config, and this restriction
    /// will simply stop applying to them. Making the arrangement itself
    /// refuse duplicates would have to be undone to get there.
    public func contains(kind: DashboardWidgetKind) -> Bool {
        tiles.contains { $0.kind == kind }
    }

    // MARK: - Mutations

    /// Adds a widget at the first free slot in reading order, appending a
    /// new row when nothing existing fits. Deliberately *not* "always at the
    /// bottom": dropping a new 1×1 into a hole the user already has is what
    /// they'd expect, and the catalogue hands off straight into edit mode,
    /// so moving it elsewhere is the very next gesture available.
    @discardableResult
    public mutating func append(kind: DashboardWidgetKind, id: UUID = UUID()) -> UUID {
        let seed = DashboardTile(id: id, kind: kind, row: 0, column: 0)
        tiles = Self.normalized(tiles + [Self.firstFreeSlot(for: seed, in: Self.occupancy(of: tiles))])
        return id
    }

    /// Places a **brand-new** widget at a specific cell.
    ///
    /// Deliberately not `append` followed by `move`. `move` can resolve a
    /// collision by trading places, which is right for two tiles that both
    /// already have somewhere to be — but a widget arriving from the
    /// catalogue has no meaningful place to trade *into*. Doing it that way
    /// sent the displaced tile to whatever slot `append` happened to pick
    /// first, which from the user's side looked like it teleported to the
    /// bottom of the dashboard for no reason.
    ///
    /// So an insert never swaps. The occupant either steps aside into a free
    /// cell in its own row, or the whole row moves down to make space:
    ///
    ///  1. **Target cells free** → place there.
    ///  2. **A 1×1 landing on a 1×1 with a free cell beside it** → the
    ///     occupant slides sideways, exactly as it does for a move.
    ///  3. **Anything else** → open a new row at the target and place into
    ///     it, pushing the rest down.
    @discardableResult
    public mutating func insert(
        kind: DashboardWidgetKind, id: UUID = UUID(), atRow row: Int, column: Int
    ) -> UUID {
        var landing = DashboardTile(id: id, kind: kind, row: max(row, 0), column: 0)
        landing.column = Self.clampedColumn(column, for: landing.size)

        let occupied = Self.occupancy(of: tiles)
        if Self.fits(landing, in: occupied) {
            tiles = Self.normalized(tiles + [landing])
        } else if let sidestepped = Self.steppingAside(for: landing, with: tiles, in: occupied) {
            tiles = Self.normalized(sidestepped)
        } else {
            tiles = Self.normalized(
                Self.pushingDown(tiles, fromRow: landing.row, by: landing.size.rows) + [landing]
            )
        }
        return id
    }

    /// Rule 2 for an insert: the occupant moves over, and nothing else on
    /// the dashboard shifts. `nil` when there is nowhere beside it to go —
    /// the caller then opens a row instead.
    private static func steppingAside(
        for landing: DashboardTile, with tiles: [DashboardTile], in occupied: [Cell: UUID]
    ) -> [DashboardTile]? {
        guard landing.size == .small,
              let occupantId = occupied[Cell(row: landing.row, column: landing.column)],
              let occupant = tiles.first(where: { $0.id == occupantId }),
              occupant.size == .small, occupant.row == landing.row,
              let freeColumn = freeColumn(in: landing.rowRange, besides: landing.column, in: occupied)
        else { return nil }

        var moved = occupant
        moved.column = freeColumn
        return tiles.filter { $0.id != occupant.id } + [moved, landing]
    }

    public mutating func remove(id: UUID) {
        tiles = Self.normalized(tiles.filter { $0.id != id })
    }

    /// Resolves a drop at `(row, column)`, in this priority order:
    ///
    ///  1. **Target cells free** → place there. This is the rule that makes
    ///     holes, and the right-column-with-empty-left arrangement,
    ///     reachable at all.
    ///  2. **1×1 onto a 1×1** → the occupant makes room. If the target row
    ///     has a free cell, it slides sideways into it and the dragged tile
    ///     takes the cell the user actually picked; only when the row is
    ///     full do the two trade places. Either way it cascades into
    ///     nothing, and the tile always lands exactly where it was dropped.
    ///  3. **Anything else onto an occupied target** → insert a fresh row
    ///     there and place into it, pushing the rest down. Never
    ///     destructive, and never sideways — a sideways shove needs
    ///     somewhere for the shoved tile to go, and every answer to that is
    ///     another cascade.
    ///
    /// The dragged tile is lifted out first, so dropping it back onto its
    /// own cell is a no-op rather than a self-swap.
    public mutating func move(id: UUID, toRow row: Int, column: Int) {
        guard let origin = tile(id: id) else { return }
        let others = tiles.filter { $0.id != id }
        var landing = origin
        landing.row = max(row, 0)
        landing.column = Self.clampedColumn(column, for: origin.size)

        let occupied = Self.occupancy(of: others)
        if Self.fits(landing, in: occupied) {
            tiles = Self.normalized(others + [landing])
        } else if let swapped = Self.makingRoom(for: landing, from: origin, with: others, in: occupied) {
            tiles = Self.normalized(swapped)
        } else {
            tiles = Self.normalized(
                Self.pushingDown(others, fromRow: landing.row, by: landing.size.rows) + [landing]
            )
        }
    }

    /// Rule 2 — only when both sides are single cells. A wide tile covers
    /// two cells and could be "swapped" with two different 1×1s at once,
    /// which has no single sensible answer; that case falls through to the
    /// row insert instead.
    ///
    /// The dragged tile always ends up on the cell the user picked. What
    /// varies is where the occupant goes: sideways into the free cell beside
    /// it when the target row has one (nothing else on the dashboard moves),
    /// and otherwise back to the cell the dragged tile was lifted out of —
    /// guaranteed free, and guaranteed to fit, since both are 1×1.
    ///
    /// The two branches agree where they overlap: dragging a tile onto its
    /// own row-neighbour makes the vacated cell the free one, so "slide
    /// sideways" and "trade places" are the same move there.
    private static func makingRoom(
        for landing: DashboardTile, from origin: DashboardTile,
        with others: [DashboardTile], in occupied: [Cell: UUID]
    ) -> [DashboardTile]? {
        guard landing.size == .small,
              let occupantId = occupied[Cell(row: landing.row, column: landing.column)],
              let occupant = others.first(where: { $0.id == occupantId }),
              occupant.size == .small, occupant.row == landing.row
        else { return nil }

        var moved = occupant
        if let freeColumn = freeColumn(in: landing.rowRange, besides: landing.column, in: occupied) {
            moved.row = landing.row
            moved.column = freeColumn
        } else {
            moved.row = origin.row
            moved.column = origin.column
        }
        return others.filter { $0.id != occupant.id } + [moved, landing]
    }

    /// A column free for the whole height of the arriving tile — every one
    /// of its rows, not just the row the finger was over.
    private static func freeColumn(in rows: Range<Int>, besides column: Int, in occupied: [Cell: UUID]) -> Int? {
        (0 ..< DashboardLayout.columnCount).first { candidate in
            candidate != column && rows.allSatisfy { occupied[Cell(row: $0, column: candidate)] == nil }
        }
    }

    /// Opens `amount` rows at `row` — the arriving tile's own height, so a
    /// two-row widget gets a two-row gap rather than half of one. A tile
    /// that merely *straddles* `row` isn't moved: normalization slides the
    /// newcomer past it instead, which is the same answer without shunting a
    /// widget the user can see is above the drop.
    private static func pushingDown(
        _ tiles: [DashboardTile], fromRow row: Int, by amount: Int
    ) -> [DashboardTile] {
        tiles.map { tile in
            guard tile.row >= row else { return tile }
            var shifted = tile
            shifted.row += amount
            return shifted
        }
    }
}
