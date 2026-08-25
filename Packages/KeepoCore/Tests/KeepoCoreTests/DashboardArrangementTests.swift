import Foundation
import Testing
@testable import KeepoCore

/// The dashboard's placement rules, asserted as a state machine. Every case
/// the design promises the user has a test here — most importantly the ones
/// a flow-packing layout could not express at all (a lone 1×1 in the right
/// column, a preserved hole), since those are the reason this is absolute
/// placement rather than a flow.
///
/// **Rows here are grid rows, and a widget is two of them** — see
/// `DashboardLayout.rowsPerWidget`. So widgets sit at rows 0, 2, 4 …, a
/// `rowCount` of 6 is three widget-heights, and a tile at an odd row is one
/// deliberately offset by half a widget.
@Suite("Dashboard arrangement")
struct DashboardArrangementTests {
    private func tile(
        _ kind: DashboardWidgetKind, _ row: Int, _ column: Int, id: UUID = UUID()
    ) -> DashboardTile {
        DashboardTile(id: id, kind: kind, row: row, column: column)
    }

    /// A 1×1 and a 1×2 — one and two columns wide, both one widget tall.
    /// Named by their sizes rather than their meaning, because these
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
            tiles: [tile(wide, 0, 0), tile(small, 2, 0), tile(wide, 4, 0)]
        )
        #expect(positions(arrangement).map { "\($0.0),\($0.1)" } == ["0,0", "2,0", "4,0"])
        #expect(arrangement.rowCount == 6)
    }

    @Test("Removing a tile leaves its hole, but collapses a row it emptied")
    func removalCollapsesOnlyFullyEmptyRows() {
        let paired = UUID()
        let alone = UUID()
        var arrangement = DashboardArrangement(
            tiles: [
                tile(small, 0, 0, id: paired), tile(small, 0, 1),
                tile(small, 2, 0, id: alone),
                tile(wide, 4, 0)
            ]
        )

        // Row 0 keeps its hole: one tile removed, one still there.
        arrangement.remove(id: paired)
        #expect(arrangement.tiles.first { $0.row == 0 }?.column == 1)
        #expect(arrangement.rowCount == 6)

        // Rows 2-3 are now empty, so they close and the wide tile rises.
        arrangement.remove(id: alone)
        #expect(arrangement.rowCount == 4)
        #expect(arrangement.tiles.first { $0.kind == wide }?.row == 2)
    }

    /// The reason the row was split in half. A tile parked half a widget
    /// below its neighbour occupies rows nothing else does, and no row is
    /// fully empty, so nothing collapses it back into alignment.
    @Test("A half-widget offset between two tiles survives normalization")
    func halfRowOffsetIsPreserved() {
        let offset = UUID()
        let arrangement = DashboardArrangement(
            tiles: [tile(small, 0, 0), tile(small, 1, 1, id: offset)]
        )

        #expect(arrangement.tile(id: offset).map { ($0.row, $0.column) }! == (1, 1))
        #expect(arrangement.rowCount == 3)
    }

    /// The other half of the same rule: a gap *nothing* occupies is not a
    /// spacer, it is a hole no gesture could remove, so it still closes.
    @Test("A gap no tile covers still collapses")
    func uncoveredGapStillCollapses() {
        let below = UUID()
        let arrangement = DashboardArrangement(
            tiles: [tile(small, 0, 0), tile(small, 3, 0, id: below)]
        )

        #expect(arrangement.tile(id: below)?.row == 2)
        #expect(arrangement.rowCount == 4)
    }

    // MARK: - Drop resolution

    @Test("Rule 1: a drop on free cells lands exactly there")
    func dropOnFreeCellLandsThere() {
        let moving = UUID()
        var arrangement = DashboardArrangement(tiles: [tile(small, 0, 0, id: moving), tile(wide, 2, 0)])

        arrangement.move(id: moving, toRow: 0, column: 1)

        #expect(arrangement.tile(id: moving)?.column == 1)
        #expect(arrangement.tile(id: moving)?.row == 0)
        #expect(arrangement.rowCount == 4)
    }

    @Test("Rule 2: a 1x1 dropped on a 1x1 with a free cell beside it pushes the occupant sideways")
    func smallOntoSmallSlidesOccupantSideways() {
        let dragged = UUID()
        let occupant = UUID()
        // Row 0 holds one tile and a hole; the dragged tile is picked up
        // from the row below and dropped straight onto the occupant.
        var arrangement = DashboardArrangement(
            tiles: [tile(small, 0, 0, id: occupant), tile(small, 2, 0, id: dragged)]
        )

        arrangement.move(id: dragged, toRow: 0, column: 0)

        // The dragged tile gets the cell the user actually picked; the
        // occupant steps aside into the hole rather than trading places.
        #expect(arrangement.tile(id: dragged).map { ($0.row, $0.column) }! == (0, 0))
        #expect(arrangement.tile(id: occupant).map { ($0.row, $0.column) }! == (0, 1))
        #expect(arrangement.rowCount == 2)
    }

    @Test("Rule 2: a 1x1 dropped on a 1x1 in a full row trades places with it")
    func smallOntoSmallOnFullRowSwaps() {
        let dragged = UUID()
        let occupant = UUID()
        let bystander = UUID()
        var arrangement = DashboardArrangement(
            tiles: [
                tile(small, 0, 0, id: occupant), tile(small, 0, 1, id: bystander),
                tile(small, 2, 0, id: dragged)
            ]
        )

        arrangement.move(id: dragged, toRow: 0, column: 0)

        #expect(arrangement.tile(id: dragged).map { ($0.row, $0.column) }! == (0, 0))
        #expect(arrangement.tile(id: occupant).map { ($0.row, $0.column) }! == (2, 0))
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
        #expect(arrangement.rowCount == 2)
    }

    @Test("Rule 3: a 1x1 dropped onto a wide tile opens a new row on the side it was dropped")
    func smallOntoWideInsertsRow() {
        let dragged = UUID()
        let below = UUID()
        var arrangement = DashboardArrangement(
            tiles: [tile(small, 0, 0, id: dragged), tile(wide, 2, 0), tile(wide, 4, 0, id: below)]
        )

        arrangement.move(id: dragged, toRow: 2, column: 1)

        // Rows 0-1 emptied and collapsed, so the inserted row is now row 0
        // and the tile kept the column the finger was over — a deliberate
        // hole.
        #expect(arrangement.tile(id: dragged).map { ($0.row, $0.column) }! == (0, 1))
        #expect(arrangement.tile(id: below)?.row == 4)
        #expect(arrangement.rowCount == 6)
    }

    @Test("A wide tile dropped on an occupied row pushes it down, never sideways")
    func wideOntoOccupiedRowInsertsRow() {
        let dragged = UUID()
        let occupant = UUID()
        var arrangement = DashboardArrangement(
            tiles: [tile(small, 0, 0, id: occupant), tile(wide, 4, 0, id: dragged), tile(small, 2, 0)]
        )

        arrangement.move(id: dragged, toRow: 0, column: 0)

        #expect(arrangement.tile(id: dragged).map { ($0.row, $0.column) }! == (0, 0))
        #expect(arrangement.tile(id: occupant)?.row == 2)
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
        let before = DashboardArrangement(tiles: [tile(small, 0, 1, id: dragged), tile(wide, 2, 0)])
        var after = before

        after.move(id: dragged, toRow: 0, column: 1)

        #expect(after == before)
    }

    // MARK: - Adding

    @Test("A new 1x1 fills an existing hole before opening a new row")
    func appendFillsHoleFirst() {
        var arrangement = DashboardArrangement(tiles: [tile(small, 0, 0), tile(wide, 2, 0)])

        let added = arrangement.append(kind: small)

        #expect(arrangement.tile(id: added).map { ($0.row, $0.column) }! == (0, 1))
        #expect(arrangement.rowCount == 4)
    }

    @Test("A new wide tile needs a whole row, so it appends below")
    func appendWideOpensNewRow() {
        var arrangement = DashboardArrangement(tiles: [tile(small, 0, 0)])

        let added = arrangement.append(kind: wide)

        #expect(arrangement.tile(id: added).map { ($0.row, $0.column) }! == (2, 0))
    }

    // MARK: - Normalization is a repair, not a rearrangement

    @Test("Normalizing an already-valid arrangement is the identity")
    func normalizationIsIdempotent() {
        let original = DashboardArrangement(
            tiles: [tile(small, 0, 1), tile(wide, 2, 0), tile(small, 4, 0), tile(small, 4, 1)]
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
        #expect(Set(arrangement.tiles.map(\.row)) == [0, 2])
    }

    @Test("An out-of-range column is pulled back into the grid")
    func outOfRangeColumnIsClamped() {
        let arrangement = DashboardArrangement(tiles: [tile(small, 0, 7), tile(wide, -3, 0)])

        #expect(arrangement.tiles.allSatisfy { $0.column >= 0 && $0.column < DashboardLayout.columnCount })
        #expect(arrangement.tiles.allSatisfy { $0.row >= 0 })
    }

    /// Dashboards saved before the row was halved store widgets one row
    /// apart, which now reads as half a widget apart — every tile overlaps
    /// its neighbour. Decoding normalizes, and this pins that repair to the
    /// layout the user actually had rather than merely to "something valid":
    /// a full-width tile on top, the two 1×1s side by side under it.
    @Test("A dashboard saved before the row split reopens with the same layout")
    func preSplitLayoutIsRepairedToItself() throws {
        let wideId = UUID()
        let leftId = UUID()
        let rightId = UUID()
        let stored = """
        [{"id":"\(wideId.uuidString)","kind":"net_worth","row":0,"column":0},
         {"id":"\(leftId.uuidString)","kind":"investing_ratio","row":1,"column":0},
         {"id":"\(rightId.uuidString)","kind":"currency_exposure","row":1,"column":1}]
        """

        let arrangement = try JSONDecoder().decode(
            DashboardArrangement.self, from: Data(stored.utf8)
        )

        #expect(arrangement.tile(id: wideId).map { ($0.row, $0.column) }! == (0, 0))
        #expect(arrangement.tile(id: leftId).map { ($0.row, $0.column) }! == (2, 0))
        #expect(arrangement.tile(id: rightId).map { ($0.row, $0.column) }! == (2, 1))
        #expect(arrangement.rowCount == 4)
    }

    @Test("Round-trips through JSON with its positions intact")
    func codableRoundTrip() throws {
        let original = DashboardArrangement(
            tiles: [tile(small, 0, 1), tile(wide, 2, 0), tile(.cashflow, 4, 0)]
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
            tiles: [tile(wide, 0, 0, id: expanding), tile(small, 2, 0, id: below)]
        )

        let layout = arrangement.resolved(
            expansion: DashboardExpansion(id: expanding, size: .widgets(2, columns: 2))
        )

        #expect(layout.tiles.first { $0.id == expanding }?.size == .widgets(2, columns: 2))
        #expect(layout.tiles.first { $0.id == below }?.row == 4)
        #expect(layout.tiles.allSatisfy { !$0.isDisplaced })
        #expect(layout.rowCount == 6)
    }

    @Test("Expanding a 1x1 displaces its row neighbour off-screen and takes the full width")
    func expandingSmallTileDisplacesNeighbour() {
        let expanding = UUID()
        let neighbour = UUID()
        let below = UUID()
        let arrangement = DashboardArrangement(
            tiles: [
                tile(small, 0, 0, id: expanding), tile(small, 0, 1, id: neighbour),
                tile(wide, 2, 0, id: below)
            ]
        )

        let layout = arrangement.resolved(
            expansion: DashboardExpansion(id: expanding, size: .widgets(2, columns: 2))
        )

        let expanded = layout.tiles.first { $0.id == expanding }
        #expect(expanded?.column == 0)
        #expect(expanded?.size == .widgets(2, columns: 2))
        // The neighbour keeps its column so the view knows which edge to
        // slide it out toward, and contributes no height.
        #expect(layout.tiles.first { $0.id == neighbour }?.isDisplaced == true)
        #expect(layout.tiles.first { $0.id == neighbour }?.column == 1)
        #expect(layout.tiles.first { $0.id == below }?.row == 4)
        #expect(layout.rowCount == 6)
    }

    @Test("Expanding to three widget-heights shifts by two of them, not by one")
    func tallExpansionShiftsByItsFullExtraHeight() {
        let expanding = UUID()
        let below = UUID()
        let arrangement = DashboardArrangement(
            tiles: [tile(.cashflow, 0, 0, id: expanding), tile(small, 2, 0, id: below)]
        )

        let layout = arrangement.resolved(
            expansion: DashboardExpansion(id: expanding, size: .widgets(3, columns: 2))
        )

        #expect(layout.tiles.first { $0.id == below }?.row == 6)
        #expect(layout.rowCount == 8)
    }

    @Test("Expansion never mutates the stored arrangement")
    func expansionLeavesStorageAlone() {
        let expanding = UUID()
        let arrangement = DashboardArrangement(
            tiles: [tile(small, 0, 0, id: expanding), tile(small, 0, 1)]
        )
        let before = arrangement.tiles

        _ = arrangement.resolved(
            expansion: DashboardExpansion(id: expanding, size: .widgets(2, columns: 2))
        )

        #expect(arrangement.tiles == before)
    }

    @Test("An expansion naming a tile that is no longer there resolves to the base layout")
    func staleExpansionFallsBackToBase() {
        let arrangement = DashboardArrangement(tiles: [tile(small, 0, 0)])

        let layout = arrangement.resolved(
            expansion: DashboardExpansion(id: UUID(), size: .widgets(2, columns: 2))
        )

        #expect(layout.rowCount == 2)
        #expect(layout.tiles.allSatisfy { $0.size == .small })
    }

    // MARK: - Widget vocabulary

    /// Every collapsed tile is exactly one widget tall.
    ///
    /// Upcoming used to be half that — the one widget on the half-row grid.
    /// It is back to full height because a half-height card could not hold
    /// its own content at a large Dynamic Type setting: the overflow drew
    /// through the gutter, so the grid's uniform 12pt gap *looked* smaller
    /// around that one tile. Keeping every base size equal is what makes the
    /// spacing independent of which widget it is next to, which is the
    /// property this pins.
    @Test("Every collapsed tile is one widget tall")
    func everyBaseSizeIsOneWidgetTall() {
        for kind in DashboardWidgetKind.allCases {
            #expect(
                kind.baseSize.rows == DashboardLayout.rowsPerWidget,
                "\(kind) must rest at the same height as every other tile"
            )
        }
    }

    @Test("Every widget's expanded sizes are full width and taller than its base")
    func expandedSizesAreAlwaysFullWidthAndTaller() {
        for kind in DashboardWidgetKind.allCases {
            #expect(kind.baseSize.rows >= 1, "\(kind) base size must occupy at least one row")
            #expect(
                kind.baseSize.columns <= DashboardLayout.columnCount,
                "\(kind) base size must fit the grid's width"
            )
            #expect(!kind.expandedSizes.isEmpty, "\(kind) must have somewhere to expand to")
            for size in kind.expandedSizes {
                #expect(size.columns == DashboardLayout.columnCount, "\(kind) must expand to full width")
                #expect(size.rows > kind.baseSize.rows, "\(kind) must gain height when expanded")
            }
        }
    }

    /// Every widget that charts a series needs a resolution to draw it at,
    /// and every widget's default config has to be one its own filter can
    /// actually offer — otherwise the filter opens with nothing selected.
    @Test("A charting widget's default granularity is one it allows")
    func defaultConfigMatchesAllowedGranularities() {
        for kind in DashboardWidgetKind.allCases where kind.hasTimeframeFilter {
            guard case .rolling(let granularity) = kind.defaultConfig.timeframe else {
                Issue.record("\(kind) must default to a rolling timeframe")
                continue
            }
            #expect(
                kind.allowedGranularities.contains(granularity),
                "\(kind) defaults to \(granularity), which its filter does not offer"
            )
        }
    }

    /// A companion is an *extra* series drawn beside the widget's own. Listing
    /// the primary metric among them would load and draw it twice.
    @Test("No widget lists its own metric as a companion")
    func companionsExcludeThePrimaryMetric() {
        for kind in DashboardWidgetKind.allCases {
            #expect(
                !kind.companionMetrics.contains(kind.defaultConfig.metric),
                "\(kind) lists its own metric as a companion"
            )
            #expect(
                Set(kind.companionMetrics).count == kind.companionMetrics.count,
                "\(kind) lists a companion twice"
            )
        }
    }

    /// Only a widget that charts something can plot a companion on its axis.
    @Test("Companions only belong to widgets that chart a series")
    func onlyChartingWidgetsHaveCompanions() {
        for kind in DashboardWidgetKind.allCases where !kind.hasTimeframeFilter {
            #expect(kind.companionMetrics.isEmpty, "\(kind) has companions but charts nothing")
        }
    }

    /// The raw values are a storage format written into `UserDefaults`;
    /// renaming one silently drops that widget off every existing dashboard.
    /// Adding one is always safe — which is why `fx_rate` could join without
    /// touching the five that were already on people's dashboards.
    @Test("Persisted widget identifiers are stable")
    func widgetRawValuesAreStable() {
        #expect(Set(DashboardWidgetKind.allCases.map(\.rawValue)) == [
            "net_worth", "investing_ratio", "currency_exposure", "upcoming_bills", "cashflow", "fx_rate"
        ])
    }

    @Test("A kind already on the dashboard is reported as present")
    func containsKind() {
        let arrangement = DashboardArrangement(tiles: [
            DashboardTile(kind: .netWorth, row: 0, column: 0)
        ])

        #expect(arrangement.contains(kind: .netWorth))
        #expect(!arrangement.contains(kind: .fxRate))
    }
}

/// Inserting a brand-new widget is not the same operation as moving one that
/// already has a place. A move may trade places; an insert must never, because
/// the arriving widget has nowhere to trade *into* — doing so flung the
/// displaced tile to an arbitrary slot at the bottom of the dashboard.
@Suite("Dashboard insertion")
struct DashboardInsertionTests {
    private let small = DashboardWidgetKind.investingRatio
    private let wide = DashboardWidgetKind.netWorth

    private func tile(_ kind: DashboardWidgetKind, _ row: Int, _ column: Int, id: UUID = UUID()) -> DashboardTile {
        DashboardTile(id: id, kind: kind, row: row, column: column)
    }

    @Test("Inserting onto a free cell lands exactly there")
    func insertOnFreeCell() {
        var arrangement = DashboardArrangement(tiles: [tile(small, 0, 0)])
        let added = arrangement.insert(kind: small, atRow: 0, column: 1)
        #expect(arrangement.tile(id: added).map { ($0.row, $0.column) }! == (0, 1))
        #expect(arrangement.rowCount == 2)
    }

    @Test("An occupant with a free cell beside it steps aside, and nothing else moves")
    func occupantStepsAside() {
        let occupant = UUID()
        let below = UUID()
        var arrangement = DashboardArrangement(
            tiles: [tile(small, 0, 0, id: occupant), tile(wide, 2, 0, id: below)]
        )

        let added = arrangement.insert(kind: small, atRow: 0, column: 0)

        #expect(arrangement.tile(id: added).map { ($0.row, $0.column) }! == (0, 0))
        #expect(arrangement.tile(id: occupant).map { ($0.row, $0.column) }! == (0, 1))
        #expect(arrangement.tile(id: below)?.row == 2)
        #expect(arrangement.rowCount == 4)
    }

    /// The case that was wrong: a full row. The occupant must go to the *next
    /// row*, not swap into wherever the newcomer nominally came from.
    @Test("A full target row is pushed down rather than swapped")
    func fullRowIsPushedDown() {
        let first = UUID()
        let second = UUID()
        var arrangement = DashboardArrangement(
            tiles: [tile(small, 0, 0, id: first), tile(small, 0, 1, id: second), tile(wide, 2, 0)]
        )

        let added = arrangement.insert(kind: small, atRow: 0, column: 0)

        #expect(arrangement.tile(id: added).map { ($0.row, $0.column) }! == (0, 0))
        // Both former occupants stay together, one widget-height further down.
        #expect(arrangement.tile(id: first)?.row == 2)
        #expect(arrangement.tile(id: second)?.row == 2)
        #expect(arrangement.tile(id: second)?.column == 1)
        #expect(arrangement.rowCount == 6)
    }

    @Test("Inserting a wide widget onto an occupied row opens a row for it")
    func wideInsertOpensARow() {
        let occupant = UUID()
        var arrangement = DashboardArrangement(tiles: [tile(small, 0, 0, id: occupant)])

        let added = arrangement.insert(kind: wide, atRow: 0, column: 0)

        #expect(arrangement.tile(id: added).map { ($0.row, $0.column) }! == (0, 0))
        #expect(arrangement.tile(id: occupant)?.row == 2)
    }

    @Test("An insert never loses the tile that was there")
    func insertNeverLosesATile() {
        let existing = (0 ..< 4).map { _ in UUID() }
        var arrangement = DashboardArrangement(
            tiles: [
                tile(small, 0, 0, id: existing[0]), tile(small, 0, 1, id: existing[1]),
                tile(wide, 2, 0, id: existing[2]), tile(wide, 4, 0, id: existing[3])
            ]
        )

        arrangement.insert(kind: small, atRow: 0, column: 1)

        #expect(arrangement.tiles.count == 5)
        for id in existing {
            #expect(arrangement.tile(id: id) != nil)
        }
    }
}
