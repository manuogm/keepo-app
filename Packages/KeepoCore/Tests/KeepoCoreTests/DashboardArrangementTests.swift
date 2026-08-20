import Foundation
import Testing
@testable import KeepoCore

/// The dashboard's placement rules, asserted as a state machine. Every case
/// the design promises the user has a test here — most importantly the ones
/// a flow-packing layout could not express at all (a lone 1×1 in the right
/// column, a preserved hole), since those are the reason this is absolute
/// placement rather than a flow.
@Suite("Dashboard arrangement")
struct DashboardArrangementTests {
    private func tile(
        _ kind: DashboardWidgetKind, _ row: Int, _ column: Int, id: UUID = UUID()
    ) -> DashboardTile {
        DashboardTile(id: id, kind: kind, row: row, column: column)
    }

    /// A 1×1 and a 1×2, by their sizes rather than their meaning — these
    /// tests are about geometry, and naming them after widgets would imply
    /// a rule that depends on which widget it is. None does.
    private let small = DashboardWidgetKind.investingRatio
    private let wide = DashboardWidgetKind.netWorth

    private func positions(_ arrangement: DashboardArrangement) -> [(Int, Int)] {
        arrangement.tiles.map { ($0.row, $0.column) }
    }

    // MARK: - The arrangements absolute placement exists to allow

    @Test("A lone 1x1 keeps the right column with an empty cell beside it")
    func loneSmallTileStaysInRightColumn() {
        let arrangement = DashboardArrangement(tiles: [tile(small, 0, 1)])
        #expect(arrangement.tiles.map(\.column) == [1])
        #expect(arrangement.tiles.map(\.row) == [0])
    }

    @Test("A hole between a wide tile and a lone 1x1 survives normalization")
    func holeIsPreserved() {
        // wide / [small, hole] / wide — the user's own example.
        let arrangement = DashboardArrangement(
            tiles: [tile(wide, 0, 0), tile(small, 1, 0), tile(wide, 2, 0)]
        )
        #expect(positions(arrangement).map { "\($0.0),\($0.1)" } == ["0,0", "1,0", "2,0"])
        #expect(arrangement.rowCount == 3)
    }

    @Test("Removing a tile leaves its hole, but collapses a row it emptied")
    func removalCollapsesOnlyFullyEmptyRows() {
        let paired = UUID()
        let alone = UUID()
        var arrangement = DashboardArrangement(
            tiles: [
                tile(small, 0, 0, id: paired), tile(small, 0, 1),
                tile(small, 1, 0, id: alone),
                tile(wide, 2, 0)
            ]
        )

        // Row 0 keeps its hole: one tile removed, one still there.
        arrangement.remove(id: paired)
        #expect(arrangement.tiles.first { $0.row == 0 }?.column == 1)
        #expect(arrangement.rowCount == 3)

        // Row 1 is now empty, so it closes and the wide tile rises into it.
        arrangement.remove(id: alone)
        #expect(arrangement.rowCount == 2)
        #expect(arrangement.tiles.first { $0.kind == wide }?.row == 1)
    }

    // MARK: - Drop resolution

    @Test("Rule 1: a drop on free cells lands exactly there")
    func dropOnFreeCellLandsThere() {
        let moving = UUID()
        var arrangement = DashboardArrangement(tiles: [tile(small, 0, 0, id: moving), tile(wide, 1, 0)])

        arrangement.move(id: moving, toRow: 0, column: 1)

        #expect(arrangement.tile(id: moving)?.column == 1)
        #expect(arrangement.tile(id: moving)?.row == 0)
        #expect(arrangement.rowCount == 2)
    }

    @Test("Rule 2: a 1x1 dropped on a 1x1 with a free cell beside it pushes the occupant sideways")
    func smallOntoSmallSlidesOccupantSideways() {
        let dragged = UUID()
        let occupant = UUID()
        // Row 0 holds one tile and a hole; the dragged tile is picked up
        // from the row below and dropped straight onto the occupant.
        var arrangement = DashboardArrangement(
            tiles: [tile(small, 0, 0, id: occupant), tile(small, 1, 0, id: dragged)]
        )

        arrangement.move(id: dragged, toRow: 0, column: 0)

        // The dragged tile gets the cell the user actually picked; the
        // occupant steps aside into the hole rather than trading places.
        #expect(arrangement.tile(id: dragged).map { ($0.row, $0.column) }! == (0, 0))
        #expect(arrangement.tile(id: occupant).map { ($0.row, $0.column) }! == (0, 1))
        #expect(arrangement.rowCount == 1)
    }

    @Test("Rule 2: a 1x1 dropped on a 1x1 in a full row trades places with it")
    func smallOntoSmallOnFullRowSwaps() {
        let dragged = UUID()
        let occupant = UUID()
        let bystander = UUID()
        var arrangement = DashboardArrangement(
            tiles: [
                tile(small, 0, 0, id: occupant), tile(small, 0, 1, id: bystander),
                tile(small, 1, 0, id: dragged)
            ]
        )

        arrangement.move(id: dragged, toRow: 0, column: 0)

        #expect(arrangement.tile(id: dragged).map { ($0.row, $0.column) }! == (0, 0))
        #expect(arrangement.tile(id: occupant).map { ($0.row, $0.column) }! == (1, 0))
        // Nothing else on the dashboard moved.
        #expect(arrangement.tile(id: bystander).map { ($0.row, $0.column) }! == (0, 1))
    }

    /// The two branches of rule 2 have to agree here or the gesture would
    /// behave differently depending on which one happened to be taken.
    @Test("Dropping a 1x1 onto its own row neighbour trades places, either way you read the rule")
    func smallOntoItsOwnNeighbourSwaps() {
        let dragged = UUID()
        let neighbour = UUID()
        var arrangement = DashboardArrangement(
            tiles: [tile(small, 0, 0, id: dragged), tile(small, 0, 1, id: neighbour)]
        )

        arrangement.move(id: dragged, toRow: 0, column: 1)

        #expect(arrangement.tile(id: dragged).map { ($0.row, $0.column) }! == (0, 1))
        #expect(arrangement.tile(id: neighbour).map { ($0.row, $0.column) }! == (0, 0))
        #expect(arrangement.rowCount == 1)
    }

    @Test("Rule 3: a 1x1 dropped onto a wide tile opens a new row on the side it was dropped")
    func smallOntoWideInsertsRow() {
        let dragged = UUID()
        let below = UUID()
        var arrangement = DashboardArrangement(
            tiles: [tile(small, 0, 0, id: dragged), tile(wide, 1, 0), tile(wide, 2, 0, id: below)]
        )

        arrangement.move(id: dragged, toRow: 1, column: 1)

        // Row 0 emptied and collapsed, so the inserted row is now row 0 and
        // the tile kept the column the finger was over — a deliberate hole.
        #expect(arrangement.tile(id: dragged).map { ($0.row, $0.column) }! == (0, 1))
        #expect(arrangement.tile(id: below)?.row == 2)
        #expect(arrangement.rowCount == 3)
    }

    @Test("A wide tile dropped on an occupied row pushes it down, never sideways")
    func wideOntoOccupiedRowInsertsRow() {
        let dragged = UUID()
        let occupant = UUID()
        var arrangement = DashboardArrangement(
            tiles: [tile(small, 0, 0, id: occupant), tile(wide, 2, 0, id: dragged), tile(small, 1, 0)]
        )

        arrangement.move(id: dragged, toRow: 0, column: 0)

        #expect(arrangement.tile(id: dragged).map { ($0.row, $0.column) }! == (0, 0))
        #expect(arrangement.tile(id: occupant)?.row == 1)
        #expect(arrangement.tile(id: occupant)?.column == 0)
    }

    @Test("A wide tile always resolves to column 0, whatever column it was dropped on")
    func wideTileClampsToColumnZero() {
        let dragged = UUID()
        var arrangement = DashboardArrangement(tiles: [tile(wide, 0, 0, id: dragged)])

        arrangement.move(id: dragged, toRow: 0, column: 1)

        #expect(arrangement.tile(id: dragged)?.column == 0)
    }

    @Test("Dropping a tile back on its own cell changes nothing")
    func dropOnSelfIsNoOp() {
        let dragged = UUID()
        let before = DashboardArrangement(tiles: [tile(small, 0, 1, id: dragged), tile(wide, 1, 0)])
        var after = before

        after.move(id: dragged, toRow: 0, column: 1)

        #expect(after == before)
    }

    // MARK: - Adding

    @Test("A new 1x1 fills an existing hole before opening a new row")
    func appendFillsHoleFirst() {
        var arrangement = DashboardArrangement(tiles: [tile(small, 0, 0), tile(wide, 1, 0)])

        let added = arrangement.append(kind: small)

        #expect(arrangement.tile(id: added).map { ($0.row, $0.column) }! == (0, 1))
        #expect(arrangement.rowCount == 2)
    }

    @Test("A new wide tile needs a whole row, so it appends below")
    func appendWideOpensNewRow() {
        var arrangement = DashboardArrangement(tiles: [tile(small, 0, 0)])

        let added = arrangement.append(kind: wide)

        #expect(arrangement.tile(id: added).map { ($0.row, $0.column) }! == (1, 0))
    }

    // MARK: - Normalization is a repair, not a rearrangement

    @Test("Normalizing an already-valid arrangement is the identity")
    func normalizationIsIdempotent() {
        let original = DashboardArrangement(
            tiles: [tile(small, 0, 1), tile(wide, 1, 0), tile(small, 2, 0), tile(small, 2, 1)]
        )

        #expect(DashboardArrangement(tiles: original.tiles) == original)
    }

    @Test("Overlapping stored tiles are separated rather than dropped")
    func overlapsAreResolved() {
        let first = UUID()
        let second = UUID()
        let arrangement = DashboardArrangement(
            tiles: [tile(wide, 0, 0, id: first), tile(wide, 0, 0, id: second)]
        )

        #expect(arrangement.tiles.count == 2)
        #expect(Set(arrangement.tiles.map(\.row)) == [0, 1])
    }

    @Test("An out-of-range column is pulled back into the grid")
    func outOfRangeColumnIsClamped() {
        let arrangement = DashboardArrangement(tiles: [tile(small, 0, 7), tile(wide, -3, 0)])

        #expect(arrangement.tiles.allSatisfy { $0.column >= 0 && $0.column < DashboardLayout.columnCount })
        #expect(arrangement.tiles.allSatisfy { $0.row >= 0 })
    }

    @Test("Round-trips through JSON with its positions intact")
    func codableRoundTrip() throws {
        let original = DashboardArrangement(
            tiles: [tile(small, 0, 1), tile(wide, 1, 0), tile(.cashflow, 2, 0)]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DashboardArrangement.self, from: data)

        #expect(decoded == original)
    }

    // MARK: - Expansion

    @Test("Expanding a wide tile pushes everything below down, displacing nothing")
    func expandingWideTileShiftsBelow() {
        let expanding = UUID()
        let below = UUID()
        let arrangement = DashboardArrangement(
            tiles: [tile(wide, 0, 0, id: expanding), tile(small, 1, 0, id: below)]
        )

        let layout = arrangement.resolved(
            expansion: DashboardExpansion(id: expanding, size: DashboardWidgetSize(rows: 2, columns: 2))
        )

        #expect(layout.tiles.first { $0.id == expanding }?.size == DashboardWidgetSize(rows: 2, columns: 2))
        #expect(layout.tiles.first { $0.id == below }?.row == 2)
        #expect(layout.tiles.allSatisfy { !$0.isDisplaced })
        #expect(layout.rowCount == 3)
    }

    @Test("Expanding a 1x1 displaces its row neighbour off-screen and takes the full width")
    func expandingSmallTileDisplacesNeighbour() {
        let expanding = UUID()
        let neighbour = UUID()
        let below = UUID()
        let arrangement = DashboardArrangement(
            tiles: [
                tile(small, 0, 0, id: expanding), tile(small, 0, 1, id: neighbour),
                tile(wide, 1, 0, id: below)
            ]
        )

        let layout = arrangement.resolved(
            expansion: DashboardExpansion(id: expanding, size: DashboardWidgetSize(rows: 2, columns: 2))
        )

        let expanded = layout.tiles.first { $0.id == expanding }
        #expect(expanded?.column == 0)
        #expect(expanded?.size == DashboardWidgetSize(rows: 2, columns: 2))
        // The neighbour keeps its column so the view knows which edge to
        // slide it out toward, and contributes no height.
        #expect(layout.tiles.first { $0.id == neighbour }?.isDisplaced == true)
        #expect(layout.tiles.first { $0.id == neighbour }?.column == 1)
        #expect(layout.tiles.first { $0.id == below }?.row == 2)
        #expect(layout.rowCount == 3)
    }

    @Test("Expanding to 3 rows shifts by 2, not by 1")
    func tallExpansionShiftsByItsFullExtraHeight() {
        let expanding = UUID()
        let below = UUID()
        let arrangement = DashboardArrangement(
            tiles: [tile(.cashflow, 0, 0, id: expanding), tile(small, 1, 0, id: below)]
        )

        let layout = arrangement.resolved(
            expansion: DashboardExpansion(id: expanding, size: DashboardWidgetSize(rows: 3, columns: 2))
        )

        #expect(layout.tiles.first { $0.id == below }?.row == 3)
        #expect(layout.rowCount == 4)
    }

    @Test("Expansion never mutates the stored arrangement")
    func expansionLeavesStorageAlone() {
        let expanding = UUID()
        let arrangement = DashboardArrangement(
            tiles: [tile(small, 0, 0, id: expanding), tile(small, 0, 1)]
        )
        let before = arrangement.tiles

        _ = arrangement.resolved(
            expansion: DashboardExpansion(id: expanding, size: DashboardWidgetSize(rows: 2, columns: 2))
        )

        #expect(arrangement.tiles == before)
    }

    @Test("An expansion naming a tile that is no longer there resolves to the base layout")
    func staleExpansionFallsBackToBase() {
        let arrangement = DashboardArrangement(tiles: [tile(small, 0, 0)])

        let layout = arrangement.resolved(
            expansion: DashboardExpansion(id: UUID(), size: DashboardWidgetSize(rows: 2, columns: 2))
        )

        #expect(layout.rowCount == 1)
        #expect(layout.tiles.allSatisfy { $0.size == .small })
    }

    // MARK: - Widget vocabulary

    @Test("Every widget's expanded sizes are full width and taller than its base")
    func expandedSizesAreAlwaysFullWidthAndTaller() {
        for kind in DashboardWidgetKind.allCases {
            #expect(kind.baseSize.rows == 1, "\(kind) base size must be one row tall")
            for size in kind.expandedSizes {
                #expect(size.columns == DashboardLayout.columnCount, "\(kind) must expand to full width")
                #expect(size.rows > kind.baseSize.rows, "\(kind) must gain height when expanded")
            }
        }
    }

    /// The raw values are a storage format written into `UserDefaults`;
    /// renaming one silently drops that widget off every existing dashboard.
    @Test("Persisted widget identifiers are stable")
    func widgetRawValuesAreStable() {
        #expect(Set(DashboardWidgetKind.allCases.map(\.rawValue)) == [
            "net_worth", "investing_ratio", "currency_exposure", "upcoming_bills", "cashflow"
        ])
    }
}
