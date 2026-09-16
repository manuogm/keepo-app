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
/// **Two stages on one step, and the first one is a question.** The kind is
/// asked on its own, as `AccountKindPicker`'s two cards, and the form does
/// not exist until it is answered. That is a reversal: this step used to
/// compress the kind into a segmented control precisely so the form could
/// share the screen with it, on the argument that the two cards took sixty
/// percent of a screen that had a form to fit. The argument was right about
/// the space and wrong about the conclusion — the fix is not to shrink the
/// question but to stop asking both at once. Each stage now gets the whole
/// screen, the cards get to be the cards they are everywhere else, and the
/// form opens with the kind already decided, which is also what lets it put
/// the Investment badge beside the name.
///
/// Everything else is reused: the icon well is `IconPickerButton`, the
/// figure is `AmountField`, the currency override is `AmountField`'s own
/// code chip, and the wording of the two kinds is `AccountKindPicker`'s, so
/// the two places that ask this question cannot describe it differently.
struct SetupAccountStep: View {
    let store: OnboardingDraftStore
    let currencies: [PublicSchema.CurrenciesSelect]

    /// Minted once and kept across Back, so a user who steps back and
    /// forward is still describing the same account rather than a second
    /// one — and so a retried commit lands on the same row.
    @State private var accountId = UUID()
    /// **Optional, and that is the stage marker.** `nil` is "has not chosen
    /// yet" and shows the cards; anything else shows the form. A separate
    /// `hasChosenKind` flag would be the same state stored twice, and the
    /// two would eventually disagree.
    @State private var kind: PublicSchema.AccountKind?
    @State private var name = ""
    @State private var balanceText = ""
    @State private var icon = AccountAppearance.defaultIcon(forKind: .regular)
    @State private var color = Color(hex: CategoryAppearance.randomColor())
    @State private var currency = ""
    /// Stops the kind from overwriting an icon the user chose themselves —
    /// going back and switching Everyday → Investment should not silently
    /// undo a deliberate pick.
    @State private var hasChosenIcon = false
    @State private var isPickingIcon = false
    @State private var isPickingCurrency = false

    var body: some View {
        OnboardingScaffold(
            title: "Create your first account",
            step: .account,
            onBack: back,
            isPrimaryEnabled: isComplete,
            isPrimaryVisible: kind != nil,
            onPrimary: next
        ) {
            if kind == nil {
                kindChoice
            } else {
                accountForm
            }
        }
        .animation(AppTheme.Motion.standard, value: kind)
        .sheet(isPresented: $isPickingIcon) {
            IconCatalogView(icon: $icon, color: $color)
        }
        .sheet(isPresented: $isPickingCurrency) {
            CurrencyPickerSheet(currencies: currencies, selection: $currency, title: "Account currency")
        }
        .onChange(of: icon) { _, _ in hasChosenIcon = true }
        .task { restore() }
    }

    // MARK: - Stage one

    private var kindChoice: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            Text("Choose an account type")
                .font(AppTheme.Typography.bodyEmphasis)
                .foregroundStyle(AppTheme.Palette.textPrimary)

            AccountKindPicker(onSelect: choose(_:))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Picking a card *is* the forward action, which is why this step has no
    /// Next button until there is a form to advance from.
    private func choose(_ chosen: PublicSchema.AccountKind) {
        if !hasChosenIcon {
            icon = AccountAppearance.defaultIcon(forKind: chosen)
            // `onChange(of: icon)` fires for that assignment too, so the
            // flag has to be put back — the pick was this line's, not the
            // user's.
            hasChosenIcon = false
        }
        kind = chosen
    }

    // MARK: - Stage two

    /// Icon, then name, then figure, straight down the middle. The name and
    /// the balance share one card because they are one thing being
    /// described — two separate fills read as two unrelated questions that
    /// happen to be stacked.
    private var accountForm: some View {
        VStack(spacing: AppTheme.Spacing.xl) {
            IconPickerButton(icon: icon, color: color, diameter: AppTheme.Size.illustration) {
                isPickingIcon = true
            }

            VStack(spacing: 0) {
                HStack(spacing: AppTheme.Spacing.s) {
                    TextField("Account name", text: $name)
                        .font(AppTheme.Typography.body)
                        .foregroundStyle(AppTheme.Palette.textPrimary)
                        .textInputAutocapitalization(.words)
                    // The same marker this account will carry on every
                    // screen it ever appears on, shown at the moment the
                    // user names it rather than as a surprise afterwards.
                    if kind == .investment {
                        InvestmentBadge()
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.m)
                .frame(minHeight: AppTheme.Size.touchTarget)

                Divider()
                    .padding(.leading, AppTheme.Spacing.m)

                // `onPickCurrency` replaces the sentence that used to sit
                // under this figure explaining that the account could be in
                // another currency. The capability was worth keeping and
                // the paragraph was not: the code chip beside the number is
                // the same offer in the place the answer belongs.
                AmountField(
                    text: $balanceText,
                    currency: selectedCurrencyInfo,
                    onPickCurrency: currencies.isEmpty ? nil : { isPickingCurrency = true },
                    size: AppTheme.Typography.Number.balance
                )
                .padding(AppTheme.Spacing.m)
            }
            .background(AppTheme.Palette.bgSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card))

            starterChips
        }
        .frame(maxWidth: .infinity)
    }

    /// The shapes almost every first account actually is. They fill in a
    /// name and an icon and nothing else — the user is still looking at an
    /// editable field, so a chip is a head start rather than a decision
    /// made for them.
    private var starterChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: AppTheme.Spacing.s) {
                ForEach(StarterAccount.all(for: kind ?? .regular), id: \.name) { starter in
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

    // MARK: - State

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var balanceE4: Int64? {
        balanceText.isEmpty ? nil : AmountParser.parse(balanceText)
    }

    private var isComplete: Bool {
        kind != nil && !trimmedName.isEmpty && balanceE4 != nil && !currency.isEmpty
    }

    private var selectedCurrencyInfo: CurrencyInfo? {
        guard let match = currencies.first(where: { $0.code == currency }) else { return nil }
        return CurrencyInfo(code: match.code, minorUnit: Int(match.minorUnit))
    }

    /// Back out of the form to the type cards first, and only then out of
    /// the step. Changing your mind about the kind is the likeliest reason
    /// to press Back here, and sending the user two screens away to do it
    /// would be answering a smaller question with a bigger undo.
    private func back() {
        if kind != nil {
            kind = nil
        } else {
            store.goBack()
        }
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
        guard let kind, let balanceE4, !currency.isEmpty else { return }
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
