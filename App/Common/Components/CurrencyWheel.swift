import KeepoCore
import SwiftUI

/// The currency question, wherever it is asked: three shortcuts, a search
/// that unfolds out of the fourth, and the wheel.
///
/// Extracted from `BaseCurrencySheet` so the sheet on My Profile and
/// onboarding's inline currency step render **one** implementation. They
/// are the same question asked in two places, and the sizing below is the
/// part that would have been got wrong twice.
///
/// **Why a wheel needs help.** A wheel is the right control for picking one
/// value out of a fixed set, and the wrong one for *finding* a value in it:
/// the supported set is ~30 entries, only one is visible at rest, and
/// reaching NZD means spinning past twenty currencies while reading each.
/// So the wheel keeps the job it is good at and one row is laid over it for
/// the job it is not — three taps for the answer almost everybody gives,
/// and a fourth that opens a field for everybody else.
///
/// **The row is one row, not two.** The search takes the shortcuts' place
/// rather than sitting under them, which is the same trade the transactions
/// filter panel makes and for the same reason: a permanently open field
/// costs a whole row of a control that is already the tallest thing on its
/// screen, to serve the minority of answers that are not one of three
/// buttons. Collapsed it is a glyph; open it is the row.
///
/// **The row font has to be asked for separately.** A `UIPickerView` row is
/// a fixed ~30pt whatever it is handed, so growing `CurrencyBadge`'s disc to
/// carry bigger letters only made neighbouring flags overlap — the code
/// size is set here instead, because at the badge's usual disc-derived size
/// it is too small to read across the room.
struct CurrencyWheel: View {
    let currencies: [PublicSchema.CurrenciesSelect]
    @Binding var selection: String
    var label = "Currency"

    /// The three that account for most of the answers this control ever
    /// gets — and, not incidentally, the three a European app's users are
    /// most likely to hold. Hardcoded rather than derived: a "most popular"
    /// list computed from anything Keepo can see would be computed from one
    /// person's own accounts, which is a different question.
    ///
    /// Each is shown only if the server actually supports it, so a currency
    /// dropped from the set cannot leave a shortcut that selects a value the
    /// wheel has no row for.
    private static let shortcuts = ["EUR", "USD", "GBP"]

    /// `UIPickerView`'s own height, which SwiftUI exposes no way to
    /// change — the number is here so the empty-search state can reserve
    /// exactly as much room and the block stops changing size as you type.
    private static let pickerHeight: CGFloat = 216

    /// The wheel plus the one control row over it. Exposed so a sheet can
    /// size a detent to this block without the number being written down
    /// twice and drifting.
    static let height: CGFloat = pickerHeight + AppTheme.Size.touchTarget + AppTheme.Spacing.m

    @State private var query = ""
    @State private var isSearching = false
    @FocusState private var isSearchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: AppTheme.Spacing.m) {
            controlRow
            wheel
        }
        .animation(AppTheme.Motion.quick, value: isSearching)
        // **Filtering moves the selection, deliberately.** A wheel is always
        // sitting on something, so when the filter removes the selected row
        // the control shows the first match while the binding still says the
        // old code — and the next tap on Next writes a currency the user can
        // no longer see. Following the wheel keeps what is displayed and what
        // would be committed the same thing, which is the property that
        // matters here.
        //
        // On the stack rather than on the `Picker`, because the picker is not
        // in the hierarchy while a search matches nothing: attached there, the
        // one transition that most needs reconciling — back from no matches to
        // some — is the one it would miss.
        .onChange(of: query) { _, _ in
            guard let first = matches.first,
                  !matches.contains(where: { $0.code == selection }) else { return }
            selection = first.code
        }
    }

    // MARK: - Shortcuts

    @ViewBuilder
    private var controlRow: some View {
        Group {
            if isSearching {
                searchField
            } else {
                HStack(spacing: AppTheme.Spacing.s) {
                    ForEach(availableShortcuts, id: \.self, content: shortcutPill)
                    searchButton
                }
            }
        }
        .frame(height: AppTheme.Size.touchTarget)
    }

    private var availableShortcuts: [String] {
        Self.shortcuts.filter { code in currencies.contains { $0.code == code } }
    }

    /// **Selected is the inverted fill, not the accent.** Mango is the app's
    /// one accent and it is already carrying the screen behind this — a
    /// second mango capsule inside a sheet that opened over a mango header
    /// reads as the header having leaked rather than as a choice. The
    /// palette names the pair for exactly this case: `textPrimary` as a fill
    /// with the fixed ink its two grounds need, which is what a selected row
    /// in Notification Settings already looks like.
    private func shortcutPill(_ code: String) -> some View {
        let isSelected = selection == code
        return Button {
            selection = code
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                CurrencyBadge(code: code, diameter: AppTheme.Size.glyph, showsCode: false)
                Text(code)
                    .font(AppTheme.Typography.bodyEmphasis)
                    // Drawn here rather than by the badge: on the selected
                    // pill the letters sit on an inked fill and have to turn
                    // over with it, and `CurrencyBadge` always writes its
                    // code in `textPrimary` — which on a `textPrimary` fill
                    // is the same colour twice.
                    .foregroundStyle(isSelected ? selectedInk : AppTheme.Palette.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: AppTheme.Size.touchTarget)
            .background(
                isSelected ? AppTheme.Palette.textPrimary : AppTheme.Palette.fillSubtle,
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.pressableCard)
        .animation(AppTheme.Motion.colorSafe, value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The fill under a selected pill is `textPrimary` itself — dark ink in
    /// light mode, a near-white in dark — so the letters on it cannot reuse
    /// that adaptive token without vanishing into their own background.
    /// Light mode's ink needs fixed white; dark mode's near-white needs
    /// fixed ink. `NotificationSettingsView` derives the same pair for the
    /// same reason; a third place doing it is the one that should extract a
    /// shared helper.
    private var selectedInk: Color {
        colorScheme == .dark ? AppTheme.Palette.textOnLight : AppTheme.Palette.textOnAccent
    }

    // MARK: - Search

    /// The fourth thing in the row, sized like the pills beside it so the
    /// set reads as one control rather than three pills and a stray glyph.
    private var searchButton: some View {
        Button {
            isSearching = true
            isSearchFocused = true
        } label: {
            KeepoIcon(name: "icon-search", size: AppTheme.Size.glyphSmall)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .frame(width: AppTheme.Size.touchTarget, height: AppTheme.Size.touchTarget)
                .background(AppTheme.Palette.fillSubtle, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.pressableCard)
        .accessibilityLabel("Search currencies")
    }

    private var searchField: some View {
        HStack(spacing: AppTheme.Spacing.s) {
            KeepoIcon(name: "icon-search", size: AppTheme.Size.glyphSmall)
                .foregroundStyle(AppTheme.Palette.textSecondary)
            TextField(
                "",
                text: $query,
                prompt: Text("Search currencies")
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            )
            .font(AppTheme.Typography.body)
            .foregroundStyle(AppTheme.Palette.textPrimary)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .focused($isSearchFocused)
            // **One control, and it does both.** Clearing the text and
            // folding the row back up are not two things a user wants
            // separately: an empty search field is a search field with no
            // job left, and leaving it open only hides the three shortcuts
            // it displaced.
            Button {
                query = ""
                isSearching = false
                isSearchFocused = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: AppTheme.Size.glyphSmall))
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close search")
        }
        .padding(.horizontal, AppTheme.Spacing.m)
        .frame(height: AppTheme.Size.touchTarget)
        .background(AppTheme.Palette.fillSubtle, in: Capsule())
    }

    /// Code **or name**, because "euro" and "dollar" are what a person
    /// reaches for when they cannot remember three letters. The name comes
    /// from `Locale`, not from the row: `currencies` carries a code and a
    /// minor unit and nothing else, and shipping a second table of names
    /// to keep in step with the system's own would be worse than asking it.
    private var matches: [PublicSchema.CurrenciesSelect] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return currencies }
        return currencies.filter { currency in
            currency.code.localizedCaseInsensitiveContains(trimmed)
                || Locale.current.localizedString(forCurrencyCode: currency.code)?
                    .localizedCaseInsensitiveContains(trimmed) == true
        }
    }

    // MARK: - Wheel

    @ViewBuilder
    private var wheel: some View {
        if matches.isEmpty {
            // Said, rather than shown as an empty wheel — a picker with no
            // rows is indistinguishable from one that failed to load.
            Text("No currency matches “\(query.trimmingCharacters(in: .whitespaces))”")
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: Self.pickerHeight)
        } else {
            Picker(label, selection: $selection) {
                ForEach(matches, id: \.code) { currency in
                    CurrencyBadge(
                        code: currency.code,
                        diameter: AppTheme.Size.glyph,
                        codeFont: AppTheme.Typography.bodyEmphasis
                    )
                    .tag(currency.code)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            // **Pinned, because a wheel is happy to be squashed.** A
            // `Picker` is flexible vertically, so between the two `Spacer`s
            // in `BaseCurrencySheet` it settled for whatever was left after
            // they took their share — six rows instead of the seven the
            // control is drawn for, at a different height from the same
            // wheel in onboarding. Asking for the one height makes the
            // block measurable, which is what `height` above promises its
            // callers.
            .frame(height: Self.pickerHeight)
        }
    }
}
