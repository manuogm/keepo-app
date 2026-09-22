import KeepoCore
import SwiftUI

/// Create and edit one recurring rule, built from the same pieces as
/// `TransactionFormView` — because it is the same act, aimed at the future.
///
/// It used to be a `Form` with seven `Section` headers ("Account",
/// "Category", "Amount", "Frequency", "Next due"…), each labelling one
/// control that already said what it was. That was exactly the shape the
/// transaction form was rebuilt away from, and this screen's own header
/// comment went on claiming it mirrored that form for months after it had
/// stopped being true. It mirrors it now, for real: a kind tab bar over a
/// single card, the account and amount in the raised block
/// `TransactionDetailContainer` draws, the category as ranked tiles rather
/// than a menu of text.
///
/// **What the two forms genuinely differ on is time.** A transaction happened
/// on a day; a rule happens every so often, starting on a day. So the slot
/// the transaction form gives its date stepper holds a frequency track with
/// the stepper under it, and the stepper's chevrons move by one period
/// rather than by one day — for a rule, "the next one" is a month away, not
/// a Tuesday away.
struct RecurringRuleFormView: View {
    let session: SessionStore
    var mode: Mode = .create
    var onSaved: () -> Void

    enum Mode {
        case create
        /// "Make recurring", pushed from a transaction the user is already
        /// looking at. Identical to `.create` in every way that reaches the
        /// server — it only spares them retyping what is on screen one view
        /// back.
        case createSeeded(
            accountId: UUID?,
            toAccountId: UUID?,
            categoryId: UUID?,
            amountText: String,
            kind: Kind,
            startingOn: Date
        )
        case edit(PublicSchema.RecurringRulesSelect)
    }

    /// `false` when pushed onto an existing `NavigationStack` (the
    /// transaction form's "Make recurring") rather than presented as its own
    /// sheet — nesting a second stack inside one breaks the back button and
    /// the swipe-to-go-back gesture alike. Same pattern as `AccountFormView`.
    var embedInNavigationStack = true

    /// The same three the transaction form offers, and deliberately the same
    /// words in the same order: the two screens are one idea seen twice, and
    /// a user who has learnt one tab bar has learnt both.
    ///
    /// Transfer arrived with migration 20260927100000. Until then
    /// `recurring_rules` held a single account/category pair and the
    /// transaction form hid its "Make recurring" button for transfers
    /// entirely — a standing transfer into savings being, in fact, the most
    /// ordinary recurring instruction there is.
    enum Kind: String, CaseIterable, Identifiable {
        case expense = "Expense"
        case income = "Income"
        case transfer = "Transfer"

        var id: String { rawValue }
    }

    @Environment(\.dismiss) var dismiss

    @State var kind: Kind = .expense
    @State var accounts: [LocalAccountRow] = []
    @State var categories: [PublicSchema.CategoriesSelect] = []
    /// The three the user reaches for most on this account, for this kind —
    /// the same `LocalCategoryRanking` the transaction form's chips read, so
    /// "the categories I actually use" means one thing in both places.
    @State var suggestedCategories: [PublicSchema.CategoriesSelect] = []

    @State var selectedAccountId: UUID?
    @State var selectedToAccountId: UUID?
    @State var selectedCategoryId: UUID?
    @State var amountText = ""
    /// Never read for a recurring transfer — the server refuses a
    /// cross-currency one, so the destination amount is always the source
    /// amount. It exists because `TransferLegsView` takes a binding for it,
    /// and handing it a constant would mean the shared component had to grow
    /// a case for this screen.
    @State var mirroredAmountText = ""
    @State var notes = ""
    /// The tags on this rule. Applied on Save, not as they are tapped — a tag
    /// toggled on a rule the user then cancels out of must not have been
    /// written. Same contract as the transaction form's.
    @State var selectedTagIds: Set<UUID> = []
    /// What the rule had when the sheet opened, so Save writes only the
    /// difference rather than re-upserting every chip.
    @State var originalTagIds: Set<UUID> = []
    @State var tagsById: [UUID: PublicSchema.TagsSelect] = [:]
    @State var isPickingTags = false

    @State var frequency: PublicSchema.RecurringFrequency = .monthly
    @State var nextDueAt = Date()
    @State var active = true

    @State var editingId: UUID?

    @State var isLoading = true
    @State var isSaving = false
    /// Validation — a field that is wrong while you are looking straight at
    /// it, which needs no dismissing. A failed *save* is `actionError`
    /// below, as an alert, which is what the rest of the app does with work
    /// that was asked for and did not happen.
    @State var errorMessage: String?
    @State var actionError: ActionError?
    /// Bumped by the period chevrons, and only by them, so their haptic
    /// fires on the tap rather than on everything else that sets
    /// `nextDueAt` — the seed, an edit's prefill, the calendar.
    @State var dateSteps = 0
    @State var isPickingDate = false

    var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var selectedAccount: LocalAccountRow? {
        accounts.first { $0.id == selectedAccountId }
    }

    var categoriesForKind: [PublicSchema.CategoriesSelect] {
        let categoryKind: PublicSchema.CategoryKind = kind == .income ? .income : .expense
        return categories.filter { $0.kind == categoryKind }
    }

    // MARK: - Body

    var body: some View {
        if embedInNavigationStack {
            NavigationStack { formContent }
        } else {
            formContent
        }
    }

    @ViewBuilder
    private var formContent: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()

            if isLoading {
                ProgressView()
            } else {
                VStack(spacing: AppTheme.Spacing.m) {
                    // Enabled in edit mode, unlike the transaction form's.
                    // There the kind is locked because changing it is
                    // delete-and-recreate at the schema level; here it is the
                    // sign of `amount_e4` plus which column the target lives
                    // in, and `RecurringRuleRepository.update` writes both —
                    // so switching an expense rule into a transfer is an
                    // ordinary edit, not a different row.
                    KindTabBar(selection: kindBinding, title: \.rawValue)
                        .padding(.horizontal, AppTheme.Spacing.l)
                        .padding(.top, AppTheme.Spacing.xs)

                    ScrollView {
                        detailCard
                            .padding(.horizontal, AppTheme.Spacing.l)
                            .padding(.bottom, AppTheme.Spacing.xl)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
        }
        .navigationTitle(isEditing ? "Edit Recurring" : "New Recurring")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if embedInNavigationStack {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button { Task { await save() } } label: { Image(systemName: "checkmark") }
                    .disabled(isSaveDisabled)
            }
        }
        .sheet(isPresented: $isPickingDate) { datePickerSheet }
        .sheet(isPresented: $isPickingTags) {
            TagPickerSheet(session: session, selectedTagIds: $selectedTagIds)
        }
        .errorAlert($actionError)
        .task { await load() }
        // One observer over one value rather than two: both questions have
        // the same two inputs — which categories this account is used for,
        // and where a transfer out of it could go — and this body is already
        // near the SwiftUI type checker's budget.
        .task(id: EntryContext(accountId: selectedAccountId, kind: kind)) { await adoptContext() }
    }

    // MARK: - The card

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
            scheduleBlock

            detailBody

            if kind == .transfer, hasHiddenDestinations {
                Text(Self.destinationRestriction)
                    .font(AppTheme.Typography.micro)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .padding(.leading, AppTheme.Spacing.xs)
            }

            // Every kind, including transfers — `materialize_recurring` puts
            // the note on both legs, matching `create_transfer`'s `p_notes`.
            TextField("Add a note…", text: $notes, axis: .vertical)
                .font(AppTheme.Typography.label)
                .lineLimit(1...4)

            if isEditing {
                activeRow
            }

            if let errorMessage {
                FormErrorText(message: errorMessage)
            }
        }
        .padding(AppTheme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Palette.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.surface))
    }

    // MARK: - The body

    /// **`TransactionDetailCard`, not a lookalike.** The recurring form used
    /// to compose that card's subcomponents by hand, because the card always
    /// draws a tag row and a rule had no tags — adding a `showsTags` flag to
    /// dodge one row would have been configurability one caller wanted.
    ///
    /// Migration 20260930100000 gave rules tags, so that reason is gone and
    /// the whole card is now genuinely the same object in both forms: account
    /// and amount, category chips or two legs, and the identical tag row.
    private var detailBody: some View {
        TransactionDetailCard(
            fromAccountId: $selectedAccountId,
            toAccountId: $selectedToAccountId,
            categoryId: $selectedCategoryId,
            amountText: $amountText,
            receivedAmountText: $mirroredAmountText,
            selectedTagIds: $selectedTagIds,
            tagsById: tagsById,
            onEditTags: { isPickingTags = true },
            accounts: accounts,
            categories: categoriesForKind,
            suggestedCategories: suggestedCategories,
            isTransfer: kind == .transfer,
            destinationAccounts: eligibleDestinations,
            // A rule's amount is a figure the user already knows — the rent,
            // the subscription — not a purchase to work out at the till.
            showsAmountCalculator: false,
            // The server refuses a cross-currency recurring transfer, so the
            // two legs are always in one currency and there is never a second
            // amount to ask for.
            needsReceivedAmount: false
        )
    }

    /// Said once, in the one place it can be acted on.
    ///
    /// Both halves are the server's (migration 20260927100000) and both have
    /// the same root: a rule fires unattended. A cross-currency one would
    /// need a destination amount, and there is no honest figure to store —
    /// money rule 6 permits a stored conversion precisely *because* a user is
    /// there to correct it with what their bank actually charged, and at 2am
    /// nobody is. A cross-owner one could not stamp its destination leg with
    /// the rule that created it.
    static let destinationRestriction =
        "Recurring transfers move money between your own accounts in the same currency."

    // MARK: - Active

    /// Paused, as a fact with a switch on it rather than a bare "Active"
    /// toggle at the bottom of a form.
    ///
    /// The word alone was the whole control, and it left the one question
    /// that matters unanswered: pausing a rule does not undo the
    /// transactions it has already made, it only stops the next one. The
    /// grey line says which.
    ///
    /// Create mode has no such row. A rule that is paused before it has ever
    /// fired is an instruction to do nothing, which is the same as not
    /// writing it down.
    private var activeRow: some View {
        HStack(spacing: AppTheme.Spacing.m) {
            KeepoIcon(name: "icon-recurrent", size: AppTheme.Size.glyph)
                .foregroundStyle(active ? AppTheme.Palette.brandPrimary : AppTheme.Palette.textSecondary)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(active ? "Active" : "Paused")
                    .font(AppTheme.Typography.labelEmphasis)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                Text(
                    active
                        ? "The next one is added automatically."
                        : "No new transactions will be added."
                )
                .font(AppTheme.Typography.micro)
                .foregroundStyle(AppTheme.Palette.textSecondary)
            }

            Spacer(minLength: AppTheme.Spacing.s)

            Toggle("", isOn: $active)
                .labelsHidden()
                .tint(AppTheme.Palette.statusPositive)
        }
        .padding(AppTheme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Palette.bgSurfaceRaised, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card))
        .animation(AppTheme.Motion.colorSafe, value: active)
        .accessibilityElement(children: .combine)
    }
}
