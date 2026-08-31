import Foundation
import KeepoCore
import Observation
import SwiftUI

/// Why the current scope has nothing to show. Every main screen asks the
/// same question and renders the same answer, so the question is asked
/// once, here, rather than three times in three different shapes.
enum ScopeEmptiness: Equatable {
    /// No accounts at all — onboarding was skipped, or every account was
    /// archived. Universal: it outranks every scope-specific case, because
    /// "share an account" is not actionable advice for someone who has none.
    case noAccounts
    /// Household scope, but the user never created or joined a household.
    case noHousehold
    /// Private scope, accounts exist, but every one of them is shared.
    case noPrivateAccounts
    /// Household scope with a household, but nothing shared into it yet.
    /// The mirror image of `noPrivateAccounts`, and answered the same way:
    /// nothing is broken, so nothing is offered.
    case noSharedAccounts
}

/// Which of the three scopes actually have anything behind them, for the
/// signed-in user right now.
///
/// Owned by `MainTabView` and handed down through the environment: all three
/// main screens need the identical answer, it is derived from the same local
/// mirror they already read, and computing it per screen would mean three
/// copies of the same query drifting apart the first time the definition of
/// "private" changed.
@Observable
@MainActor
final class ScopeContext {
    private(set) var hasAnyAccount = false
    private(set) var hasPrivateAccount = false
    private(set) var hasSharedAccount = false
    private(set) var hasHousehold = false
    /// False until the first read lands. Every blank state below is a claim
    /// about the user's data, and claiming "you have no accounts" before
    /// having looked is worse than showing nothing at all.
    private(set) var isLoaded = false

    func reload(session: SessionStore) async {
        guard let ownerId = session.profile?.id.uuidString else { return }
        let dbQueue = session.dbQueue
        let loaded = try? await dbQueue.read { database in
            (
                try LocalTableQueries.scopeAvailability(database, ownerId: ownerId),
                try LocalTableQueries.myHousehold(database, userId: ownerId)
            )
        }
        guard let loaded else { return }
        hasAnyAccount = loaded.0.visibleCount > 0
        hasSharedAccount = loaded.0.sharedCount > 0
        hasPrivateAccount = loaded.0.visibleCount > loaded.0.sharedCount
        hasHousehold = loaded.1 != nil
        isLoaded = true
    }

    /// `nil` means "this scope has data — render the screen".
    func emptiness(for scope: PublicSchema.AccountScope) -> ScopeEmptiness? {
        guard isLoaded else { return nil }
        return ScopeEmptiness.resolve(
            scope: scope, hasAnyAccount: hasAnyAccount, hasPrivateAccount: hasPrivateAccount,
            hasSharedAccount: hasSharedAccount, hasHousehold: hasHousehold
        )
    }
}

extension ScopeEmptiness {
    /// The whole decision, as a pure function of four facts — so the table
    /// can be pinned by a test without standing up a session, a database and
    /// a view.
    ///
    /// "No accounts at all" is checked first and wins outright, per the
    /// user's own rule for the Private case: someone with nothing to look at
    /// needs to be told to add an account, not to go and share one.
    static func resolve(
        scope: PublicSchema.AccountScope,
        hasAnyAccount: Bool,
        hasPrivateAccount: Bool,
        hasSharedAccount: Bool,
        hasHousehold: Bool
    ) -> ScopeEmptiness? {
        guard hasAnyAccount else { return .noAccounts }
        switch scope {
        case .total:
            return nil
        case .me:
            return hasPrivateAccount ? nil : .noPrivateAccounts
        case .household:
            if !hasHousehold { return .noHousehold }
            return hasSharedAccount ? nil : .noSharedAccounts
        }
    }
}
