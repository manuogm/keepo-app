import Foundation
import KeepoCore
import Observation

/// Owns the user's widget arrangement and its persistence. Every mutation
/// goes through `DashboardArrangement`'s rules (which normalize and compact)
/// and is written straight back to disk — there is no "save" step to forget,
/// and no in-memory copy that can drift from what the next launch will read.
///
/// Storage is device-local `UserDefaults`, by decision rather than by
/// omission — see `AppSettingsKeys.dashboardArrangement`. This type is the
/// entire seam: promoting the arrangement to a synced Supabase table later
/// changes this file and nothing that renders.
@Observable
@MainActor
final class DashboardStore {
    private(set) var arrangement: DashboardArrangement

    private let defaults: UserDefaults

    /// A fresh install lands on the Net Worth widget alone — the same figure
    /// Home led with before the dashboard existed, so upgrading loses
    /// nothing and a new user gets something real rather than an empty grid
    /// and a tutorial.
    static let seed = DashboardArrangement(
        tiles: [DashboardTile(kind: .netWorth, row: 0, column: 0)]
    )

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Absent key and empty array are deliberately NOT the same thing: a
        // user who removes their last widget has asked for the blank state,
        // and re-seeding them back to Net Worth on the next launch would
        // silently undo that. Only a never-configured dashboard is seeded.
        guard let data = defaults.data(forKey: AppSettingsKeys.dashboardArrangement) else {
            self.arrangement = Self.seed
            return
        }
        self.arrangement = (try? JSONDecoder().decode(DashboardArrangement.self, from: data)) ?? Self.seed
    }

    @discardableResult
    func append(kind: DashboardWidgetKind) -> UUID {
        var updated = arrangement
        let id = updated.append(kind: kind)
        apply(updated)
        return id
    }

    func remove(id: UUID) {
        var updated = arrangement
        updated.remove(id: id)
        apply(updated)
    }

    func move(id: UUID, toRow row: Int, column: Int) {
        var updated = arrangement
        updated.move(id: id, toRow: row, column: column)
        apply(updated)
    }

    /// The kinds currently on screen — the dashboard's loader takes this and
    /// computes nothing for a widget the user doesn't have.
    var mountedKinds: Set<DashboardWidgetKind> {
        Set(arrangement.tiles.map(\.kind))
    }

    private func apply(_ updated: DashboardArrangement) {
        guard updated != arrangement else { return }
        arrangement = updated
        // A failed encode would mean the arrangement silently reverts on the
        // next launch. It cannot fail for this shape (three ints and a
        // string per tile), and there is no user-facing recovery worth
        // showing if it somehow did — so this drops it rather than raising
        // an alert nobody can act on.
        guard let data = try? JSONEncoder().encode(updated) else { return }
        defaults.set(data, forKey: AppSettingsKeys.dashboardArrangement)
    }
}
