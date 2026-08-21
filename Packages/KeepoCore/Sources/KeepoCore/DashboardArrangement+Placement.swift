import Foundation

/// The placement primitives every mutation in `DashboardArrangement` shares,
/// plus the resolver that turns a stored arrangement into the frames a view
/// actually draws. Split out purely to keep each file under the project's
/// length lint — there is no ordering dependency between the two halves.
extension DashboardArrangement {
    /// One grid cell. A named type rather than a tuple because a bare pair
    /// of `Int`s is exactly the shape whose two members get silently
    /// swapped at a call site.
    struct Cell: Hashable {
        let row: Int
        let column: Int
    }

    static func occupancy(of tiles: [DashboardTile]) -> [Cell: UUID] {
        var occupied: [Cell: UUID] = [:]
        for tile in tiles {
            for cell in tile.cells {
                occupied[cell] = tile.id
            }
        }
        return occupied
    }

    static func fits(_ tile: DashboardTile, in occupied: [Cell: UUID]) -> Bool {
        guard tile.row >= 0, tile.column >= 0,
              tile.column + tile.size.columns <= DashboardLayout.columnCount
        else { return false }
        return tile.cells.allSatisfy { occupied[$0] == nil }
    }

    /// A wide tile has exactly one legal column, so this collapses to 0 for
    /// it — the caller never has to special-case width.
    static func clampedColumn(_ column: Int, for size: DashboardWidgetSize) -> Int {
        min(max(column, 0), DashboardLayout.columnCount - size.columns)
    }

    /// The first position at or after `start`, in reading order, where
    /// `tile` fits. Terminates because the scan is allowed to run one row
    /// past the last occupied one, and nothing at all sits below that.
    static func firstFreeSlot(
        for tile: DashboardTile, in occupied: [Cell: UUID], from start: Cell = Cell(row: 0, column: 0)
    ) -> DashboardTile {
        let lastRow = occupied.keys.map(\.row).max() ?? -1
        for row in start.row ... (max(lastRow, start.row) + 1) {
            let firstColumn = row == start.row ? max(start.column, 0) : 0
            for column in firstColumn ..< DashboardLayout.columnCount {
                var candidate = tile
                candidate.row = row
                candidate.column = column
                if fits(candidate, in: occupied) { return candidate }
            }
        }
        var fallback = tile
        fallback.row = max(lastRow, start.row) + 1
        fallback.column = 0
        return fallback
    }

    /// Resolves overlaps and out-of-range positions deterministically, then
    /// drops fully empty rows. Tiles are processed in reading order, so a
    /// tile keeps its own position whenever that position is still free and
    /// only ever slides *forward* — which makes normalizing an already-valid
    /// arrangement the identity, the property every mutation above relies on.
    static func normalized(_ tiles: [DashboardTile]) -> [DashboardTile] {
        var occupied: [Cell: UUID] = [:]
        var placed: [DashboardTile] = []

        for tile in tiles.sorted(by: isBefore) {
            var candidate = tile
            candidate.row = max(tile.row, 0)
            candidate.column = clampedColumn(tile.column, for: tile.size)
            if !fits(candidate, in: occupied) {
                candidate = firstFreeSlot(
                    for: candidate, in: occupied, from: Cell(row: candidate.row, column: candidate.column)
                )
            }
            for cell in candidate.cells {
                occupied[cell] = candidate.id
            }
            placed.append(candidate)
        }
        return compactingEmptyRows(placed)
    }

    /// A row with one tile and one hole is **not** empty and is never
    /// touched — preserving those holes is the whole point of absolute
    /// placement. This only closes rows nothing occupies at all, which
    /// otherwise become blank bands no gesture can remove.
    ///
    /// "Occupied" means *covered*, not *started in*: a two-row widget owns
    /// its second row as much as its first, so counting only `tile.row`
    /// would read every widget's lower half as an empty band and collapse
    /// the dashboard onto itself. Each tile then slides up by however many
    /// genuinely empty rows sit above it, which preserves both its height
    /// and any deliberate half-row gap a spacer is holding open.
    private static func compactingEmptyRows(_ tiles: [DashboardTile]) -> [DashboardTile] {
        let occupiedRows = Set(tiles.flatMap { $0.rowRange })
        guard let lastRow = occupiedRows.max() else { return tiles }

        var emptyRowsAbove: [Int: Int] = [:]
        var empties = 0
        for row in 0 ... lastRow {
            if occupiedRows.contains(row) {
                emptyRowsAbove[row] = empties
            } else {
                empties += 1
            }
        }
        return tiles.map { tile in
            var compacted = tile
            compacted.row -= emptyRowsAbove[tile.row] ?? 0
            return compacted
        }.sorted(by: isBefore)
    }

    private static func isBefore(_ lhs: DashboardTile, _ rhs: DashboardTile) -> Bool {
        (lhs.row, lhs.column) < (rhs.row, rhs.column)
    }
}

extension DashboardTile {
    /// Every cell this tile covers. The one place a tile's footprint is
    /// expanded into cells, so occupancy and collision testing can never
    /// disagree about how tall a widget is.
    var cells: [DashboardArrangement.Cell] {
        rowRange.flatMap { row in
            columnRange.map { DashboardArrangement.Cell(row: row, column: $0) }
        }
    }
}

// MARK: - Resolving to drawable frames

/// Which tile is currently expanded, and to which of its `expandedSizes`.
public struct DashboardExpansion: Sendable, Equatable {
    public let id: UUID
    public let size: DashboardWidgetSize

    public init(id: UUID, size: DashboardWidgetSize) {
        self.id = id
        self.size = size
    }
}

/// A tile with the geometry it should draw at *right now* — base position
/// when nothing is expanded, shifted position when something above it is.
public struct DashboardResolvedTile: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: DashboardWidgetKind
    public let row: Int
    public let column: Int
    public let size: DashboardWidgetSize
    /// The tile sharing a row with something that expanded over it. It keeps
    /// its `column` so the view knows which edge to slide it out toward, and
    /// it contributes no height — it is off-screen, not laid out.
    public let isDisplaced: Bool
}

public struct DashboardResolvedLayout: Sendable, Equatable {
    public let tiles: [DashboardResolvedTile]
    /// Rows the container must be tall enough to draw. Excludes displaced
    /// tiles, which are off-screen by definition.
    public let rowCount: Int
}

public extension DashboardArrangement {
    /// The stored arrangement is never mutated by an expansion — collapsing
    /// restores the previous screen exactly, because the previous screen was
    /// always still the source of truth.
    ///
    /// An expanded tile is always full width, so every tile overlapping its
    /// rows is displaced. Everything below shifts down by the rows the
    /// expansion added.
    func resolved(expansion: DashboardExpansion? = nil) -> DashboardResolvedLayout {
        guard let expansion, let target = tile(id: expansion.id) else {
            return DashboardResolvedLayout(
                tiles: tiles.map {
                    DashboardResolvedTile(
                        id: $0.id, kind: $0.kind, row: $0.row, column: $0.column,
                        size: $0.size, isDisplaced: false
                    )
                },
                rowCount: rowCount
            )
        }

        let extraRows = max(expansion.size.rows - target.size.rows, 0)
        let resolved = tiles.map { tile in
            resolve(tile, target: target, expansion: expansion, extraRows: extraRows)
        }
        let height = resolved.filter { !$0.isDisplaced }.map { $0.row + $0.size.rows }.max() ?? 0
        return DashboardResolvedLayout(tiles: resolved, rowCount: height)
    }

    private func resolve(
        _ tile: DashboardTile, target: DashboardTile, expansion: DashboardExpansion, extraRows: Int
    ) -> DashboardResolvedTile {
        if tile.id == target.id {
            return DashboardResolvedTile(
                id: tile.id, kind: tile.kind, row: tile.row, column: 0,
                size: expansion.size, isDisplaced: false
            )
        }
        // Anything sharing a *row* with the expanding tile is in its way,
        // not just anything starting on the same row — a widget spans two of
        // them, so a half-row-offset neighbour overlaps just as completely.
        if tile.rowRange.overlaps(target.rowRange) {
            return DashboardResolvedTile(
                id: tile.id, kind: tile.kind, row: tile.row, column: tile.column,
                size: tile.size, isDisplaced: true
            )
        }
        let isBelow = tile.row >= target.rowRange.upperBound
        return DashboardResolvedTile(
            id: tile.id, kind: tile.kind, row: tile.row + (isBelow ? extraRows : 0),
            column: tile.column, size: tile.size, isDisplaced: false
        )
    }
}
