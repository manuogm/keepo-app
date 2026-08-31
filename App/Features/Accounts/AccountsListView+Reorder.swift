import KeepoCore
import SwiftUI

// The flat-list drag model, split out of AccountsListView.swift purely to
// keep that file under the project's file-length lint threshold — same
// precedent as TransactionFormView+Transfer.swift.

extension AccountsListView {
    /// One row in the single `ForEach` the whole drag model depends on.
    /// Headers are items, not `Section` headers, so a drag can land on
    /// either side of one and mean something.
    enum Item: Identifiable {
        case header(PublicSchema.AccountKind)
        case account(LocalAccountRow)

        var id: String {
            switch self {
            case .header(let kind): return "header-\(kind.rawValue)"
            case .account(let row): return row.id.uuidString
            }
        }
    }

    func accounts(for kind: PublicSchema.AccountKind) -> [LocalAccountRow] {
        kind == .regular ? everyday : investments
    }

    private func isHeader(_ item: Item) -> Bool {
        if case .header = item { return true }
        return false
    }

    /// Everyday first, then Investments — each header followed by its own
    /// rows, unless the group is collapsed. A collapsed group keeps its
    /// header, which is what still makes it a valid drop target: an account
    /// dropped straight after a collapsed "Investments" header is below that
    /// header and above nothing, so it converts exactly as it would if the
    /// group were open.
    var items: [Item] {
        var result: [Item] = [.header(.regular)]
        if isEverydayExpanded {
            result += everyday.map(Item.account)
        }
        result.append(.header(.investment))
        if isInvestmentsExpanded {
            result += investments.map(Item.account)
        }
        return result
    }

    /// The entire drag model. Rebuilds the flat list, applies SwiftUI's move
    /// to it, then reads the result back out: each account's kind is the
    /// kind of the nearest header above it, and its order is its position in
    /// that run. Nothing here needs to know whether the user dragged within
    /// a group or across one — that distinction only exists in the diff
    /// afterwards, which decides which writes to send.
    func handleMove(from offsets: IndexSet, to destination: Int) async {
        // Headers are NOT `.moveDisabled` — that was tried and is what broke
        // both boundary cases. A non-movable row makes its own index a dead
        // zone in UIKit's drop targeting: dragging up across the header was
        // refused outright (no `onMove` call at all), and dragging down onto
        // it resolved to the index *above* it, so "first in Investments" was
        // unreachable while "last in Everyday" was the only thing the gap
        // could mean. Leaving headers movable makes every index a legal
        // destination — UIKit displaces the header out of the way as you
        // drag over it, which is also what makes both sides of the boundary
        // visibly reachable — and a header drag is simply ignored here.
        guard isReorderable else { return }
        guard !offsets.contains(where: { isHeader(items[$0]) }) else { return }

        var moved = items
        moved.move(fromOffsets: offsets, toOffset: destination)

        let (regrouped, investmentGroup) = regroup(moved)
        let kindChanges = kindChanges(regular: regrouped, investment: investmentGroup)

        // Apply to the UI first, in one animation, so the row settles where
        // the finger left it rather than snapping back and then jumping once
        // the writes land.
        withAnimation(.snappy(duration: 0.25)) {
            everyday = regrouped
            investments = investmentGroup
        }

        await submit(kindChanges: kindChanges, regular: regrouped, investment: investmentGroup)
    }

    /// Walks the moved flat list once, assigning every account to whichever
    /// header it currently sits under. A row dragged above the very first
    /// header has no header above it; it falls into Everyday, which is the
    /// only sane reading of "dropped at the very top".
    private func regroup(_ moved: [Item]) -> (regular: [LocalAccountRow], investment: [LocalAccountRow]) {
        var currentKind: PublicSchema.AccountKind = .regular
        var regular: [LocalAccountRow] = []
        var investment: [LocalAccountRow] = []

        for item in moved {
            switch item {
            case .header(let kind):
                currentKind = kind
            case .account(let row):
                if currentKind == .regular {
                    regular.append(row)
                } else {
                    investment.append(row)
                }
            }
        }

        // A collapsed group contributes no rows to the flat list, so its own
        // accounts would silently vanish from the result. Splice them back
        // in — they were never on screen to be dragged.
        if !isEverydayExpanded { regular = everyday + regular }
        if !isInvestmentsExpanded { investment = investments + investment }

        return (regular, investment)
    }

    /// Which accounts crossed a header, and which way. Compared against the
    /// row's own `kind` rather than against the previous arrays, so a row
    /// that merely moved within its group is never counted.
    private func kindChanges(
        regular: [LocalAccountRow], investment: [LocalAccountRow]
    ) -> [(row: LocalAccountRow, kind: PublicSchema.AccountKind)] {
        regular.filter { $0.kind != .regular }.map { ($0, PublicSchema.AccountKind.regular) }
            + investment.filter { $0.kind != .investment }.map { ($0, PublicSchema.AccountKind.investment) }
    }

    /// Kind first, then order. The two writes are independent server-side —
    /// `reorder_accounts` deliberately leaves `version` alone (see migration
    /// 20260903100000 §1b), so it cannot invalidate the `expectedVersion`
    /// the kind change is carrying, in either order. Kind still goes first
    /// so that if only one of the two ever reaches the server, it is the one
    /// carrying real meaning.
    ///
    /// Both go through `session.outbox`, so a drag made offline queues and
    /// replays like every other write rather than silently reverting.
    private func submit(
        kindChanges: [(row: LocalAccountRow, kind: PublicSchema.AccountKind)],
        regular: [LocalAccountRow],
        investment: [LocalAccountRow]
    ) async {
        for change in kindChanges {
            await session.outbox.submitSetAccountKind(
                SetAccountKindPayload(
                    id: change.row.id, expectedVersion: change.row.version, kind: change.kind
                )
            )
        }

        await session.outbox.submitReorderAccounts(
            ReorderAccountsPayload(kind: .regular, accountIds: regular.map(\.id))
        )
        await session.outbox.submitReorderAccounts(
            ReorderAccountsPayload(kind: .investment, accountIds: investment.map(\.id))
        )

        // Re-read rather than trusting the in-memory arrays: `kind` on the
        // rows still says what it said before the drag, and the balances/
        // subtotals are recomputed from the same local mirror the writes
        // just landed in.
        await load()
    }
}
