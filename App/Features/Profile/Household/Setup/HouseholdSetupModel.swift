import KeepoCore
import Observation
import SwiftUI

/// What the setup flow has loaded, and what the user has chosen so far.
///
/// ## Why this is a class and not `@State` on the flow
///
/// It was `@State` on `HouseholdSetupFlow`, and the accounts step rendered
/// **empty even though the load had already put two accounts in it** — proven
/// in the simulator with four seconds between the two log lines:
///
/// ```
/// HH load  … matched=2                    ← state written
/// HH render accountsStep sees 0 accounts  ← the pushed screen reads 0
/// ```
///
/// The cause is `navigationDestination(for:)`. Its closure is captured from a
/// body evaluation, and the step was a computed property on the flow — so
/// reading `accounts` inside it read the `self` **struct copy** that closure
/// captured, which was made before `load()` finished. The write went to the
/// live `@State` storage; the pushed screen was looking at a snapshot.
///
/// A reference type removes the class of bug rather than the instance:
/// Observation tracks the read where it actually happens, at render time,
/// against one shared object — so it cannot matter which copy of the
/// enclosing struct the closure happens to hold. **Do not move these back
/// onto the view.**
@Observable
@MainActor
final class HouseholdSetupModel {
    /// Your own live accounts, the only ones you may offer.
    var accounts: [LocalAccountRow] = []
    /// Your own categories, minus the two "Other" defaults — `share_category`
    /// refuses those, and a control that always fails is worse than none.
    var categories: [PublicSchema.CategoriesSelect] = []

    var selectedAccountIds: Set<UUID> = []
    /// The selected accounts that come with their past transactions. Off by
    /// default (user's decision, 2026-09-23): an account the user switches
    /// on is shared from the day the household is made.
    var fullHistoryAccountIds: Set<UUID> = []
    var selectedCategoryIds: Set<UUID> = []

    /// What the pickers amount to, as `create_invite`/`accept_invite` take
    /// it. A history choice on an account that was switched back off is not
    /// a choice about anything, so it is dropped here.
    var choices: HouseholdShareChoices {
        HouseholdShareChoices(
            accountIds: Array(selectedAccountIds),
            fullHistoryAccountIds: Array(fullHistoryAccountIds.intersection(selectedAccountIds)),
            categoryIds: Array(selectedCategoryIds)
        )
    }

    /// False until the first read lands. The pickers draw a spinner rather
    /// than "you have no accounts to share yet", which is a claim about the
    /// user's data that must not be made before looking — the same rule
    /// `ScopeContext.isLoaded` exists for.
    private(set) var isLoaded = false

    func load(session: SessionStore) async {
        guard let ownerId = session.profile?.id.uuidString,
              let viewerId = session.profile?.id else { return }
        let baseCurrency = session.profile?.baseCurrency ?? "EUR"

        let loaded = try? await session.dbQueue.read { database in
            (
                try LocalAccountRow.fetchAll(database, ownerId: ownerId, baseCurrency: baseCurrency),
                try LocalTableQueries.categories(database, ownerId: ownerId)
            )
        }
        guard let loaded else { return }

        // Only your own, and only the live ones. An archived account holds no
        // money the household would see, and the other member's accounts are
        // not yours to offer.
        accounts = loaded.0.filter { $0.ownerId == viewerId && $0.archivedAt == nil }
        categories = loaded.1.filter { !$0.isDefault }
        isLoaded = true
    }
}

/// What one member brings into the household, carried unchanged from the
/// pickers to the server: the owner's to `create_invite`, the guest's to
/// `accept_invite`.
struct HouseholdShareChoices {
    var accountIds: [UUID] = []
    /// The chosen accounts shared with their past transactions; the rest are
    /// shared from the day the invite is accepted.
    var fullHistoryAccountIds: [UUID] = []
    var categoryIds: [UUID] = []
}
