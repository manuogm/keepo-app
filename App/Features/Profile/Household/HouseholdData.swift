import Foundation
import GRDB
import KeepoCore
import SwiftUI

/// Everything the household screens show, read once from the local mirror.
///
/// One snapshot for the report's five screens *and* for the live Household
/// screen, because the spec asks them to show the same facts and the only way
/// two screens showing the same facts stay honest is by asking the same
/// question. The report is this snapshot mid-setup; the Household screen is
/// this snapshot afterwards.
///
/// Local reads throughout (Phase L6), so the whole thing works offline —
/// except `peer`, which comes from `household_member_profile()` over the
/// network because `profiles_select` keeps the other member's row out of the
/// mirror by design. Its absence never blocks the rest: the container falls
/// back to a name-less avatar, exactly as it does before a photo is set.
struct HouseholdSnapshot {
    var household: PublicSchema.HouseholdsSelect?
    var peer: HouseholdMemberProfile?

    var baseCurrency: CurrencyInfo?
    /// Money rule 5: `nil` is "cannot be computed" — a missing FX rate
    /// somewhere in the household — and renders as `—`, never as 0.
    var netWorthE4: Int64?
    var currencySlices: [CurrencyExposureLocal]?

    /// Every account in the household, both members'. Split at the point of
    /// use rather than here, so the one list stays the one list.
    var sharedAccounts: [LocalAccountRow] = []
    /// Your own accounts that are *not* shared — what the summary's toggles
    /// can still turn on.
    var privateAccounts: [LocalAccountRow] = []

    var mergedCategories: [HouseholdMergedCategory] = []
    /// Shared categories that are only one member's — the report's "Extra".
    var extraCategories: [HouseholdExtraCategory] = []
    /// Your own unshared categories, for the summary's toggles.
    var privateCategories: [PublicSchema.CategoriesSelect] = []

    var tags: [PublicSchema.TagsSelect] = []

    var hasHousehold: Bool { household != nil }

    // MARK: - Derived

    func accounts(ownedBy viewer: UUID?, mine: Bool) -> [LocalAccountRow] {
        sharedAccounts.filter { mine ? $0.ownerId == viewer : $0.ownerId != viewer }
    }

    var everydayCount: Int { sharedAccounts.filter { $0.kind == .regular }.count }
    var investmentCount: Int { sharedAccounts.filter { $0.kind == .investment }.count }

    func merged(_ kind: PublicSchema.CategoryKind) -> [HouseholdMergedCategory] {
        mergedCategories.filter { $0.kind == kind }
    }

    func extras(_ kind: PublicSchema.CategoryKind) -> [HouseholdExtraCategory] {
        extraCategories.filter { $0.category.kind == kind }
    }

    /// The share each currency is of the household's money.
    ///
    /// Taken against the sum of the **absolute** values, not the net total.
    /// A household holding €10,000 and a −€2,000 card has a net worth of
    /// €8,000, and shares of 125% and −25% against it — arithmetically
    /// correct and unreadable. Against the gross, the card is a quarter of
    /// what is being tracked, which is what the row is trying to say.
    func share(of slice: CurrencyExposureLocal) -> Double? {
        guard let slices = currencySlices else { return nil }
        let gross = slices.reduce(0.0) { $0 + abs(Double($1.amountBaseE4)) }
        guard gross > 0 else { return nil }
        return abs(Double(slice.amountBaseE4)) / gross
    }
}

/// Two categories that are one category: one row per member, sharing a group.
struct HouseholdMergedCategory: Identifiable, Equatable {
    let groupId: UUID
    /// The row you own — the one you can file transactions under.
    let mine: PublicSchema.CategoriesSelect
    let theirs: PublicSchema.CategoriesSelect
    /// Whether the fuzzy pass made this decision rather than a person. Drives
    /// the robot glyph in the merge sheet.
    let isAutomatic: Bool

    var id: UUID { groupId }
    var kind: PublicSchema.CategoryKind { mine.kind }
    /// Both rows carry the resultant identity, so either answers this.
    var name: String { mine.name }
    var icon: String { mine.icon }
    var color: String { mine.color }
}

/// A shared category only one of you originally had. The other member has a
/// copy so they can use it, but nothing was merged.
struct HouseholdExtraCategory: Identifiable, Equatable {
    let category: PublicSchema.CategoriesSelect
    /// Whose category this originally was.
    let isMine: Bool
    /// The other member's copy, which a manual merge would replace.
    let twinId: UUID

    var id: UUID { category.id }
}

// MARK: - Loading

@MainActor
enum HouseholdDataLoader {
    static func load(session: SessionStore) async -> HouseholdSnapshot {
        guard let viewer = session.profile?.id else { return HouseholdSnapshot() }
        let baseCurrency = session.profile?.baseCurrency ?? "EUR"

        var snapshot = (try? await session.dbQueue.read { database in
            try loadLocal(database, viewer: viewer, baseCurrency: baseCurrency)
        }) ?? HouseholdSnapshot()

        // Best-effort and last, so an offline device still renders everything
        // above. The container draws an initial for a member it cannot name,
        // which is the same thing it draws for a member with no photo.
        if snapshot.hasHousehold {
            snapshot.peer = try? await HouseholdRepository.memberProfile(client: session.client)
        }
        return snapshot
    }

    private nonisolated static func loadLocal(
        _ database: Database, viewer: UUID, baseCurrency: String
    ) throws -> HouseholdSnapshot {
        var snapshot = HouseholdSnapshot()
        snapshot.household = try LocalTableQueries.myHousehold(database, userId: viewer.uuidString)

        let now = Date()
        let today = PostgresDate.dateOnlyString(now, calendar: utcCalendar)
        let moneyScope = LocalMoneyScope(scope: .household, baseCurrency: baseCurrency)

        snapshot.baseCurrency = try LocalTableQueries.currencies(database)
            .first { $0.code == baseCurrency }
            .map { CurrencyInfo(code: $0.code, minorUnit: Int($0.minorUnit)) }
        snapshot.netWorthE4 = try LocalMoneyConversion.netWorth(
            database, moneyScope, asOf: today, now: now
        )
        snapshot.currencySlices = try LocalDashboardQueries.currencyExposure(database, moneyScope, now: now)

        let accounts = try LocalAccountRow.fetchAll(
            database, ownerId: viewer.uuidString, baseCurrency: baseCurrency
        )
        // Archived accounts are excluded from both lists. They contribute
        // nothing to the household's money (`net_worth` skips them) and
        // offering to share one would be offering to share nothing.
        let live = accounts.filter { $0.archivedAt == nil }
        snapshot.sharedAccounts = live.filter(\.isShared)
        snapshot.privateAccounts = live.filter { !$0.isShared && $0.ownerId == viewer }

        let categories = try LocalTableQueries.householdCategories(database)
        snapshot.privateCategories = categories.filter {
            $0.ownerId == viewer && $0.sharedGroupId == nil && !$0.isDefault
        }
        (snapshot.mergedCategories, snapshot.extraCategories) = split(categories, viewer: viewer)

        snapshot.tags = try LocalTableQueries.tags(database)
        return snapshot
    }

    /// Sorts every shared group into merged or extra.
    ///
    /// `merge_origin` is the discriminator and the only one that works — see
    /// the column's own note in `20260913100000_household_setup_and_report
    /// .sql` for why names, timestamps and transaction counts all fail here.
    ///
    /// A group missing one of its two rows is skipped rather than guessed at:
    /// the invariant is one row per member, and a half-group means a pull
    /// landed mid-write. It reappears on the next refresh.
    private nonisolated static func split(
        _ categories: [PublicSchema.CategoriesSelect], viewer: UUID
    ) -> ([HouseholdMergedCategory], [HouseholdExtraCategory]) {
        let shared = categories.filter { $0.sharedGroupId != nil && !$0.isDefault }
        let groups = Dictionary(grouping: shared) { $0.sharedGroupId ?? UUID() }

        var merged: [HouseholdMergedCategory] = []
        var extra: [HouseholdExtraCategory] = []

        for (groupId, rows) in groups {
            guard let mine = rows.first(where: { $0.ownerId == viewer }),
                  let theirs = rows.first(where: { $0.ownerId != viewer }) else { continue }

            if let origin = mine.mergeOrigin ?? theirs.mergeOrigin {
                merged.append(
                    HouseholdMergedCategory(
                        groupId: groupId, mine: mine, theirs: theirs, isAutomatic: origin == .automatic
                    )
                )
            } else {
                // Not merged: one of you brought it and the other got a copy.
                // Which of you is not recorded anywhere — and does not need to
                // be, because `created_at` orders the pair correctly for this
                // one purpose: the copy is inserted by `ensure_category_twin`
                // in the transaction that shares the original, so it is never
                // the earlier of the two.
                let originalIsMine = mine.createdAt <= theirs.createdAt
                let original = originalIsMine ? mine : theirs
                let copy = originalIsMine ? theirs : mine
                extra.append(
                    HouseholdExtraCategory(
                        category: original, isMine: originalIsMine, twinId: copy.id
                    )
                )
            }
        }

        merged.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        extra.sort {
            $0.category.name.localizedCaseInsensitiveCompare($1.category.name) == .orderedAscending
        }
        return (merged, extra)
    }
}
