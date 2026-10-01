import KeepoCore
import SwiftUI

/// The bulk of a transaction, as one component with three shapes.
///
/// Expense and Income are structurally identical — an account + amount
/// block, then a category row and a wrapping row of tag chips; only which
/// categories are offered differs. A transfer gets the tag row too, under
/// its two legs: a transfer carries no category, so only an all-categories
/// tag can reach it, but that is the picker's rule to state rather than a
/// control to hide here. A transfer is two of the same account+amount blocks with the
/// direction of travel drawn down the left, because that is literally what
/// a transfer is: the same money leaving one container and arriving in
/// another. Building it out of the same subcomponent rather than a separate
/// transfer layout is what keeps the two legs looking like peers.
struct TransactionDetailCard: View {
    @Binding var fromAccountId: UUID?
    @Binding var toAccountId: UUID?
    @Binding var categoryId: UUID?
    @Binding var amountText: String
    @Binding var receivedAmountText: String

    /// The tags on this transaction, the ones suggested for it, and the way
    /// into the sheet. Held by the form (it is what Save writes), rendered
    /// here.
    let tags: TagRowModel

    let accounts: [LocalAccountRow]
    let categories: [PublicSchema.CategoriesSelect]
    /// Up to three, most-used first, for the account and kind on screen —
    /// ordered by `LocalCategoryRanking`, filled out by
    /// `CategorySuggestions`. Short only when the user has fewer than three
    /// categories of this kind; empty only when they have none, which no
    /// account reaches, since everybody keeps a default "Other".
    let suggestedCategories: [PublicSchema.CategoriesSelect]
    /// How the category picker offers a category that does not exist yet.
    /// `nil` — a form that cannot create one on the account on screen — draws
    /// the picker exactly as it was. See `CategoryCreation`.
    var categoryCreation: CategoryCreation?
    let isTransfer: Bool
    /// What the transfer's DESTINATION picker may offer, when that is
    /// narrower than `accounts`. `nil` means the same list on both ends. The
    /// transaction form passes what `TransferPairing` allows the chosen
    /// source to reach; the recurring form passes a narrower list still,
    /// because a rule's two accounts must share an owner and a currency
    /// (migration 20260927100000).
    var destinationAccounts: [LocalAccountRow]?
    /// Only ever set for expense/income. A transfer's legs are each already
    /// in their own account's currency, so there is no third one to name —
    /// `needsReceivedAmount` below is that case, and it predates this.
    var foreign: ForeignAmount?
    /// Off for a captured transaction — see `TransactionDetailContainer
    /// .showsAmountCalculator`. Transfers never carry it: a transfer is
    /// always hand-entered.
    var showsAmountCalculator = true
    /// Only meaningful for a transfer, and only when the two accounts hold
    /// different currencies — otherwise the received amount is the sent
    /// amount and asking for it twice is asking the user to agree with
    /// themselves.
    let needsReceivedAmount: Bool
    /// The half of a transfer that is on an account this viewer cannot see,
    /// if one is. See `TransferLegsView.hiddenSide`.
    var hiddenTransferSide: TransferSide?
    /// What is wrong with the amount — and, on a transfer between two
    /// currencies, with the received amount — plus the counter that shakes
    /// whichever block holds it. See `TransactionDetailContainer.amountIssue`.
    var amountIssue: AmountIssue?
    var receivedAmountIssue: AmountIssue?
    var amountRejections = 0

    /// Tags deselected in the row while this form is open. They stay in the
    /// row, hollow, so a tap made by mistake is undone by tapping again
    /// rather than by finding the tag in the sheet.
    @State private var keptTagIds: Set<UUID> = []

    var body: some View {
        if isTransfer {
            transferBody
        } else {
            ledgerBody
        }
    }

    /// One row of pills plus the way into the sheet, wrapping onto as many
    /// lines as it needs. Shown for **every** kind, transfers included.
    ///
    /// Every pill toggles in place: filled is on this transaction, hollow is
    /// a suggestion or a tag just taken off. Nothing moves when tapped, so
    /// the row can be worked by position.
    private var tagRow: some View {
        TagFlowLayout(spacing: AppTheme.Spacing.s) {
            ForEach(rowTags, id: \.id) { tag in
                let isSelected = tags.selectedTagIds.contains(tag.id)
                Button { toggle(tag.id) } label: {
                    TagChip(name: tag.name, isSelected: isSelected)
                }
                .buttonStyle(.pressableCard)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            Button(action: tags.onOpenSheet) {
                AddTagButton(title: suggestedTags.isEmpty ? "Add Tags" : "All Tags")
            }
            .buttonStyle(.pressableCard)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sensoryFeedback(AppTheme.Feedback.selection, trigger: tags.selectedTagIds)
        .onChange(of: tags.entry) { keptTagIds = [] }
    }

    private var suggestedTags: [PublicSchema.TagsSelect] {
        tags.suggestedTagIds.compactMap { tags.tagsById[$0] }
    }

    /// The suggestions first, best first, then every other tag on the
    /// transaction — or taken off it here — by name. Resolved through
    /// `tagsById`, so the order is stable: a `Set` has none, and rendering
    /// one directly made the chips jump around every time one was toggled.
    private var rowTags: [PublicSchema.TagsSelect] {
        let suggested = Set(tags.suggestedTagIds)
        let others = tags.selectedTagIds.union(keptTagIds)
            .subtracting(suggested)
            .compactMap { tags.tagsById[$0] }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return suggestedTags + others
    }

    private func toggle(_ id: UUID) {
        if tags.selectedTagIds.contains(id) {
            tags.selectedTagIds.remove(id)
            keptTagIds.insert(id)
        } else {
            tags.selectedTagIds.insert(id)
        }
    }

    // MARK: - Expense / Income

    private var ledgerBody: some View {
        VStack(spacing: AppTheme.Spacing.m) {
            TransactionDetailContainer(
                accountId: $fromAccountId,
                amountText: $amountText,
                accounts: accounts,
                excluding: nil,
                showsAmountCalculator: showsAmountCalculator,
                foreign: foreign,
                amountIssue: amountIssue,
                amountRejections: amountRejections
            )

            CategorySuggestionRow(
                selection: $categoryId, suggestions: suggestedCategories, categories: categories,
                creation: categoryCreation
            )

            tagRow
        }
    }

    // MARK: - Transfer

    private var transferBody: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            TransferLegsView(
                fromAccountId: $fromAccountId,
                toAccountId: $toAccountId,
                amountText: $amountText,
                receivedAmountText: $receivedAmountText,
                accounts: accounts,
                destinationAccounts: destinationAccounts,
                needsReceivedAmount: needsReceivedAmount,
                showsAmountCalculator: showsAmountCalculator,
                hiddenSide: hiddenTransferSide,
                amountIssue: amountIssue,
                receivedAmountIssue: receivedAmountIssue,
                amountRejections: amountRejections
            )
            tagRow
        }
    }
}

/// What the tag row needs from its form, as one value.
struct TagRowModel {
    @Binding var selectedTagIds: Set<UUID>
    let tagsById: [UUID: PublicSchema.TagsSelect]
    /// Best first, at most three — `TagSuggestions`. Empty where a form
    /// offers none.
    var suggestedTagIds: [UUID] = []
    /// Changes when the form starts a new entry without closing ("Save and
    /// Add Another"), so tags taken off the last one leave the row.
    var entry = 0
    let onOpenSheet: () -> Void
}
