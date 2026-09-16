import KeepoCore
import SwiftUI

/// Step 3 — the only step with no honest default, and therefore the only
/// one with no Skip.
///
/// Keepo without an account is an app that can do nothing at all: there is
/// nowhere for a balance to be, nowhere for a capture to land, and the
/// dashboard the user is about to build has nothing to draw. Every other
/// step has something reasonable behind it; this one does not, which is
/// what `SetupStep.isSkippable` encodes.
///
/// Almost everything on it is reused: the icon well is
/// `IconPickerButton`, the figure is `AmountField`, and the currency
/// override is `CurrencyPickerSheet`. The starter chips are the one new
/// thing, and they are a shortcut past the naming rather than a different
/// way to make an account.
///
/// **The kind is a segmented control here, not `AccountKindPicker`'s two
/// cards.** Those cards are sized to be the whole of a screen whose only
/// job is that choice, which is what the Add Account sheet roots on — put
/// on this step they took sixty percent of it and pushed the name, icon
/// and balance below the fold, under a Next button that was disabled for
/// reasons the user could not see. The cards' own doc comment is the
/// argument for shrinking it: the two kinds behave identically, the choice
/// is reversible by dragging a row on the Accounts list, and it drives a
/// badge rather than a capability. It does not deserve the screen. The
/// wording is still `AccountKindPicker`'s, read from it, so the two places
/// that ask this question cannot describe it differently.
struct SetupAccountStep: View {
    let store: OnboardingDraftStore
    let currencies: [PublicSchema.CurrenciesSelect]

    /// Minted once and kept across Back, so a user who steps back and
    /// forward is still describing the same account rather than a second
    /// one — and so a retried commit lands on the same row.
    @State private var accountId = UUID()
    @State private var kind: PublicSchema.AccountKind = .regular
    @State private var name = ""
    @State private var balanceText = ""
    @State private var icon = AccountAppearance.defaultIcon(forKind: .regular)
    @State private var color = Color(hex: CategoryAppearance.randomColor())
    @State private var currency = ""
    /// Stops the kind cards from overwriting an icon the user chose
    /// themselves — switching Everyday → Investment should not silently
    /// undo a deliberate pick.
    @State private var hasChosenIcon = false
    @State private var isPickingIcon = false
    @State private var isPickingCurrency = false

    var body: some View {
        OnboardingScaffold(
            title: "Your first account",
            subtitle: "Where your money actually is. You can add the rest later.",
            step: .account,
            onBack: store.goBack,
            isPrimaryEnabled: isComplete,
            onPrimary: next
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                kindPicker
                starterChips
                identityRow
                balanceBlock
            }
        }
        .sheet(isPresented: $isPickingIcon) {
            IconCatalogView(icon: $icon, color: $color)
        }
        .sheet(isPresented: $isPickingCurrency) {
            CurrencyPickerSheet(currencies: currencies, selection: $currency, title: "Account currency")
        }
        .onChange(of: icon) { _, _ in hasChosenIcon = true }
        .onChange(of: kind) { _, newKind in adoptDefaultIcon(for: newKind) }
        .task { restore() }
    }

    // MARK: - Pieces

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            Picker("Account kind", selection: $kind) {
                ForEach([PublicSchema.AccountKind.regular, .investment], id: \.self) { candidate in
                    Text(AccountKindPicker.title(for: candidate)).tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .sensoryFeedback(AppTheme.Feedback.selection, trigger: kind)

            Text(AccountKindPicker.subtitle(for: kind))
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The three shapes almost every first account actually is. They fill
    /// in a name and an icon and nothing else — the user is still looking
    /// at an editable field, so a chip is a head start rather than a
    /// decision made for them.
    private var starterChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: AppTheme.Spacing.s) {
                ForEach(StarterAccount.all(for: kind), id: \.name) { starter in
                    Button {
                        name = starter.name
                        icon = starter.icon
                    } label: {
                        Text(starter.name)
                            .font(AppTheme.Typography.label)
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                            .padding(.horizontal, AppTheme.Spacing.m)
                            .frame(height: AppTheme.Size.icon)
                            .background(AppTheme.Palette.fillSubtle, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .sensoryFeedback(AppTheme.Feedback.selection, trigger: name)
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private var identityRow: some View {
        HStack(spacing: AppTheme.Spacing.l) {
            IconPickerButton(icon: icon, color: color, diameter: AppTheme.Size.illustration) {
                isPickingIcon = true
            }
            TextField("Account name", text: $name)
                .font(AppTheme.Typography.body)
                .textInputAutocapitalization(.words)
                .padding(AppTheme.Spacing.m)
                .background(AppTheme.Palette.bgSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.control))
        }
    }

    private var balanceBlock: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            AmountField(
                text: $balanceText, currency: selectedCurrencyInfo, size: AppTheme.Typography.Number.balance
            )
            Text("What's in it right now. Every balance from here is this figure plus everything you log after it.")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Quiet, and offered rather than asked: most first accounts are
            // in the base currency, but the feature deck sells multi-
            // currency two screens earlier, and an expat whose salary lands
            // in another currency should not have to finish setup wrong and
            // fix it afterwards.
            Button {
                isPickingCurrency = true
            } label: {
                // Only the verb carries the accent. A whole amber sentence
                // reads as something being wrong, and nothing is — this is
                // an answer most accounts never need.
                Text("This account is in \(currency). ")
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    + Text("Change")
                    .foregroundStyle(AppTheme.Palette.brandPrimary)
            }
            .font(AppTheme.Typography.caption)
            .buttonStyle(.plain)
            .disabled(currencies.isEmpty)
        }
    }

    // MARK: - State

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var balanceE4: Int64? {
        balanceText.isEmpty ? nil : AmountParser.parse(balanceText)
    }

    private var isComplete: Bool {
        !trimmedName.isEmpty && balanceE4 != nil && !currency.isEmpty
    }

    private var selectedCurrencyInfo: CurrencyInfo? {
        guard let match = currencies.first(where: { $0.code == currency }) else { return nil }
        return CurrencyInfo(code: match.code, minorUnit: Int(match.minorUnit))
    }

    private func adoptDefaultIcon(for newKind: PublicSchema.AccountKind) {
        guard !hasChosenIcon else { return }
        icon = AccountAppearance.defaultIcon(forKind: newKind)
        // `onChange(of: icon)` fires for that assignment too, so the flag
        // has to be put back — the pick was this function's, not the user's.
        hasChosenIcon = false
    }

    private func restore() {
        currency = store.draft.account?.currency ?? store.draft.baseCurrency ?? ""
        guard let account = store.draft.account else { return }
        accountId = account.id
        kind = account.kind
        name = account.name
        icon = account.icon
        color = Color(hex: account.color)
        hasChosenIcon = true
        if account.openingBalanceE4 != 0 || !account.name.isEmpty {
            balanceText = AmountFormatter.editableString(
                account.openingBalanceE4, minorUnit: selectedCurrencyInfo?.minorUnit ?? 2
            )
        }
    }

    private func next() {
        guard let balanceE4, !currency.isEmpty else { return }
        store.update {
            $0.account = DraftAccount(
                id: accountId, name: trimmedName, kind: kind, currency: currency,
                openingBalanceE4: balanceE4, icon: icon,
                color: color.hexString ?? CategoryAppearance.randomColor()
            )
        }
        store.advance()
    }
}

/// The three (or two) shapes a first account usually takes. Data rather
/// than three copy-pasted buttons, and per kind because offering "Checking"
/// to someone who just said "Investment" is offering the wrong list.
private struct StarterAccount {
    let name: String
    let icon: String

    static func all(for kind: PublicSchema.AccountKind) -> [StarterAccount] {
        switch kind {
        case .regular:
            return [
                StarterAccount(name: "Checking", icon: "banknote.fill"),
                StarterAccount(name: "Cash", icon: "dollarsign.circle.fill"),
                StarterAccount(name: "Credit Card", icon: "creditcard.fill")
            ]
        case .investment:
            return [
                StarterAccount(name: "Brokerage", icon: "chart.line.uptrend.xyaxis"),
                StarterAccount(name: "Retirement", icon: "building.columns.fill")
            ]
        }
    }
}
