import KeepoCore
import SwiftUI

/// Create and edit share one form, mirroring `TransactionFormView`.
///
/// Rebuilt from a `Form` into a `ScrollView` of cards. The old version
/// labelled every field with its own `Section` header ("Name", "Currency",
/// "Opening balance", "Icon", "Color") — six labels for six controls that
/// each already say what they are. Here the icon *is* the icon picker, the
/// large number *is* the balance, and the only text that survives is the
/// text the user cannot infer.
///
/// **The balance field is the same control in both modes but not the same
/// number**, which is the one genuinely subtle thing in this file:
///
///   * Creating — it is the account's opening balance, and goes out as
///     `CreateAccountPayload.openingBalanceE4`.
///   * Editing — it is what the account is worth *right now*, and goes out
///     through `set_account_balance`, which computes the gap server-side and
///     files an adjustment transaction. The opening balance is not shown at
///     all, and is carried through `update_account` untouched in
///     `loadedOpeningBalanceE4`. Letting the field write it directly would
///     silently overwrite the account's opening balance with its current
///     one — the exact bug version-logs/lessons-learned.md records from the
///     old cache-fallback read.
struct AccountFormView: View {
    let session: SessionStore
    var mode: Mode = .create(kind: .regular)
    var onSaved: () -> Void

    /// `false` when pushed onto `AddAccountFlowView`'s stack (create) rather
    /// than being the sheet's own root (edit) — skips the nested
    /// `NavigationStack` and the cancellation "x" (back button + swipe cover it).
    var embedInNavigationStack = true

    /// Set only by `AddAccountFlowView`: closes the whole sheet after save,
    /// since a pushed `dismiss()` would only pop back to the chooser.
    var onDismissRequested: (() -> Void)?

    enum Mode {
        case create(kind: PublicSchema.AccountKind)
        case edit(UUID)
    }

    @Environment(\.dismiss) private var dismiss

    func dismissSelf() {
        if let onDismissRequested {
            onDismissRequested()
        } else {
            dismiss()
        }
    }

    @State var currencies: [PublicSchema.CurrenciesSelect] = []
    @State var name = ""
    @State var currency = ""
    /// Opening balance while creating; current balance while editing. See
    /// the type's own header comment — these are different numbers.
    @State var balanceText = ""
    /// The stored opening balance, loaded once in edit mode and never shown.
    /// `update_account` needs it verbatim; nothing on screen may change it.
    @State var loadedOpeningBalanceE4: Int64 = 0
    /// What the balance field was prefilled with, so save can tell whether
    /// the user actually moved it — `set_account_balance` should not file an
    /// adjustment transaction for an untouched field.
    @State var loadedBalanceText = ""
    @State var includeInTotal = true
    @State var icon = AccountAppearance.defaultIcon(forKind: .regular)
    @State var color = Color(hex: CategoryAppearance.randomColor())
    @State var isShared = false
    @State var hasHousehold = false

    @State var editingId: UUID?
    @State var editingVersion: Int?
    @State var editingKind: PublicSchema.AccountKind?
    @State var editingArchivedAt: String?

    @State var isLoading = true
    @State var isSaving = false
    @State var errorMessage: String?

    @State private var isPickingIcon = false
    @State private var isPickingCurrency = false
    @State var showDeleteOptions = false
    @State var isShowingCardHelp = false
    @State var showUnshareConfirm = false

    @State var cardMappings: [PublicSchema.CardMappingsSelect] = []
    @State var editingCard: MappedCardEditor?

    var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var selectedCurrencyInfo: CurrencyInfo? {
        currencies.first { $0.code == currency }.map { CurrencyInfo(code: $0.code, minorUnit: Int($0.minorUnit)) }
    }

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
            Color(.systemGroupedBackground).ignoresSafeArea()
            if isLoading {
                ProgressView()
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        IconPickerButton(icon: icon, color: color) { isPickingIcon = true }
                            .padding(.top, 8)

                        identityAndBalanceCard
                        mappedCardsStrip
                        togglesCard

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
                // Pinned rather than the last thing in the scroll view: the
                // destructive action belongs at the bottom of the SHEET, in
                // one predictable place, not at the bottom of however much
                // content this particular account happens to have.
                .safeAreaInset(edge: .bottom) {
                    if isEditing {
                        DestructiveActionButton(title: "Delete Account", isEnabled: !isSaving) {
                            showDeleteOptions = true
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 12)
                        .background(.bar)
                    }
                }
            }
        }
        .navigationTitle(isEditing ? "Edit Account" : "New Account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(isPresented: $isPickingIcon) {
            IconCatalogView(icon: $icon, color: $color)
        }
        .sheet(isPresented: $isPickingCurrency) {
            CurrencyPickerSheet(currencies: currencies, selection: $currency)
        }
        .sheet(isPresented: $isShowingCardHelp) {
            LinkedCardsHelpSheet()
        }
        .sheet(item: $editingCard) { editor in
            MappedCardSheet(session: session, editor: editor, accountColor: color) {
                Task { await loadCardMappings() }
            }
        }
        .deleteAccountDialog(
            accountName: name,
            isPresented: $showDeleteOptions,
            onArchive: { Task { await setArchived(true) } },
            onDelete: { Task { await deletePermanently() } }
        )
        .unshareConfirmation(isPresented: $showUnshareConfirm) {
            Task { await setShared(false) }
        }
        .task { await load() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if embedInNavigationStack {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismissSelf() } label: { Image(systemName: "xmark") }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                Task { await save() }
            } label: {
                Image(systemName: "checkmark")
            }
            .disabled(isSaveDisabled)
        }
    }

    // MARK: - Cards

    /// Name and balance in ONE card, not two. They are the same question —
    /// "which account, and how much is in it" — and splitting them put a gap
    /// through the middle of the only thing on this screen the user came for.
    /// No "Name" label: a text field showing "Account Name" in grey has
    /// already said so.
    private var identityAndBalanceCard: some View {
        FormCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField("Account Name", text: $name)
                        .font(.title3.weight(.medium))
                        .textInputAutocapitalization(.words)
                    if editingKind == .investment {
                        InvestmentBadge()
                    }
                    if isShared {
                        SharedWithHouseholdIcon()
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    AmountField(text: $balanceText, currency: selectedCurrencyInfo, size: 44)
                    // Create only. An account's currency is immutable once it
                    // exists (no RPC changes it), so on edit there is nothing
                    // to offer — the symbol in front of the figure already
                    // says which currency this is, and a disabled pill
                    // repeating it in code form is just noise.
                    if !isEditing {
                        currencyPicker
                    }
                }
            }
        }
    }

    private var currencyPicker: some View {
        Button {
            isPickingCurrency = true
        } label: {
            HStack(spacing: 4) {
                Text(currency)
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(.tertiarySystemGroupedBackground), in: Capsule())
        }
        .buttonStyle(.pressableCard)
    }

    /// Include in Balance first: it is the one that changes a number the
    /// user can see elsewhere in the app, and it applies to every account.
    /// Sharing is conditional on having a household at all.
    private var togglesCard: some View {
        FormCard(padding: 0) {
            VStack(spacing: 0) {
                Toggle("Include in Balance", isOn: $includeInTotal)
                    .tint(.green)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .sensoryFeedback(.selection, trigger: includeInTotal)
                Divider().padding(.leading, 16)
                shareToggleRow
            }
        }
    }

    /// Sharing is the one control here that is not offline-capable and not
    /// symmetrical: `share_account` is a plain link, but `unshare_account`
    /// FORKS the account into an independent copy for the other member
    /// (migration 20260816100000). Turning the toggle off is therefore not
    /// an undo, and it says so before it happens.
    @ViewBuilder
    private var shareToggleRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Share with Household", isOn: shareBinding)
                .tint(.green)
                .disabled(!hasHousehold || isSaving)
            if !hasHousehold {
                Text("Create a household in Profile first.")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var shareBinding: Binding<Bool> {
        Binding(
            get: { isShared },
            set: { newValue in
                if newValue {
                    Task { await setShared(true) }
                } else {
                    showUnshareConfirm = true
                }
            }
        )
    }

    var isSaveDisabled: Bool {
        isLoading || isSaving
            || name.trimmingCharacters(in: .whitespaces).isEmpty
            || balanceText.isEmpty
            || (!isEditing && currency.isEmpty)
    }
}
