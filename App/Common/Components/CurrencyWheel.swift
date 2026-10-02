import KeepoCore
import SwiftUI

/// The currency question, wherever it is asked: three shortcuts, a search
/// that unfolds out of the fourth, and the wheel.
///
/// Extracted from what is now `CurrencyWheelSheet` (below) so that sheet and
/// onboarding's inline currency step render **one** implementation. They
/// are the same question asked in two places, and the sizing below is the
/// part that would have been got wrong twice.
///
/// **Why a wheel needs help.** A wheel is the right control for picking one
/// value out of a fixed set, and the wrong one for *finding* a value in it:
/// the supported set is ~30 entries, only one is visible at rest, and
/// reaching NZD means spinning past twenty currencies while reading each.
/// So the wheel keeps the job it is good at and one row is laid over it for
/// the job it is not — three taps for the currencies this user actually
/// holds (EUR, USD and GBP until they hold any), and a fourth that opens a
/// field for everything else.
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

    /// The user's own currencies, most important first, read from the
    /// cache so the pills are right on the sheet's first frame. See
    /// `PreferredCurrencyCache`; empty before the first refresh, and in
    /// onboarding, where the pills are simply the defaults.
    @AppStorage(PreferredCurrencyCache.key) private var preferredRaw = ""

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

    /// Three pills: the user's own currencies first, topped up with EUR,
    /// USD and GBP (`CurrencyShortcuts.pills`). Only currencies the server
    /// supports, so no pill can select a value the wheel has no row for.
    private var availableShortcuts: [String] {
        CurrencyShortcuts.pills(
            preferred: PreferredCurrencyCache.codes(from: preferredRaw),
            supported: Set(currencies.map(\.code))
        )
    }

    /// **Selected is the inverted fill, not the accent.** Teal is the app's
    /// accent and it is already carrying the screen behind this — a second
    /// teal capsule inside a sheet that opened over a teal header reads as
    /// the header having leaked rather than as a choice. The
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

    /// The fill under a selected pill is `textPrimary` itself, so the
    /// letters on it cannot reuse that adaptive token without vanishing
    /// into their own background. The third caller is what finally
    /// extracted the pair into `inkOnPrimaryFill`.
    private var selectedInk: Color {
        AppTheme.Palette.inkOnPrimaryFill(colorScheme)
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
            // in `CurrencyWheelSheet` it settled for whatever was left after
            // they took their share — six rows instead of the seven the
            // control is drawn for, at a different height from the same
            // wheel in onboarding. Asking for the one height makes the
            // block measurable, which is what `height` above promises its
            // callers.
            .frame(height: Self.pickerHeight)
        }
    }
}

/// The currency picker, wherever one is presented as a sheet: one spinning
/// wheel, dead centre of a half sheet, and nothing else on it. My Profile's
/// base currency, onboarding's first account, a new account on the Accounts
/// tab and the transaction form's "Paid In" all open this — `title` is the
/// only thing that differs. It replaced a searchable list the account and
/// transaction forms used to share; the wheel's own search row covers what
/// the list was for.
///
/// It was a scrolling `List` of tappable rows, which is the wrong shape for
/// this. Picking a currency is choosing one value out of a fixed set —
/// the same job iOS gives a wheel everywhere it appears — and a list of
/// thirty near-identical rows makes the reader hunt through them, while a
/// wheel puts the current one under the finger and spins the rest past it.
/// The wheel itself is `CurrencyWheel`, shared with onboarding's currency
/// step — including the row-font sizing, whose reasoning lives there now.
///
/// The wheel writes to a **draft**, not straight through to the caller. A
/// wheel emits a selection for every currency it passes on the way to the
/// one you wanted, and for the base currency each of those would have been a
/// `PATCH`, a profile refresh, and a full app-wide re-read. The checkmark is
/// what commits.
struct CurrencyWheelSheet: View {
    let currencies: [PublicSchema.CurrenciesSelect]
    @Binding var selection: String
    /// What is being chosen — "Base Currency", "Currency". It was hardcoded
    /// to the first, so onboarding's first-account step asked for a "Base
    /// Currency" while choosing the account's own.
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    /// `CurrencyWheel`'s own height, plus the inline title bar above it and
    /// a little air either side. The chrome is written out rather than taken
    /// from `AppTheme`: its scales size glyphs, gaps and corners, and a sheet
    /// detent is none of those — inventing a token for one screen's height
    /// would put a number on the scale that nothing else could ever reach
    /// for. The wheel's half is **asked for**, though, so adding a control
    /// above the picker cannot leave this sheet clipping it.
    private static let chromeHeight: CGFloat = 104
    private static let sheetHeight: CGFloat = CurrencyWheel.height + chromeHeight

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.Palette.bgCanvas.ignoresSafeArea()
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    CurrencyWheel(currencies: currencies, selection: $draft, label: title)
                        // The picker runs full-bleed on its own; the two
                        // controls above it are ordinary content and take the
                        // screen edge. Applied by the caller because
                        // onboarding's scaffold has already inset its content
                        // by the same amount.
                        .padding(.horizontal, AppTheme.Spacing.l)
                    Spacer(minLength: 0)
                }
            }
            // The search field's return key says Done, but a sheet this size
            // is mostly keyboard once one is up, and a tap on what is left of
            // it should be a way out.
            .dismissesKeyboardOnTap()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        selection = draft
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel("Use this currency")
                    .disabled(draft.isEmpty)
                }
            }
            // A profile with no base currency yet has nothing for the wheel
            // to land on, and an unmatched selection leaves it parked on the
            // first row while the binding still says "". Seeding from that
            // first row makes what the wheel shows and what the checkmark
            // would write the same thing.
            .onAppear {
                draft = selection.isEmpty ? (currencies.first?.code ?? "") : selection
            }
        }
        // Sized to its contents rather than to `.medium`, which the rest of
        // the app's pick-one-value sheets use. Those hold a list that grows
        // into whatever height it is given; this holds a wheel, and a wheel
        // is a fixed 216pt however much room it has — at half a screen it
        // floated in an empty field, and the rows cannot be made taller to
        // fill one (`UIPickerView` sets its own row height, and SwiftUI
        // exposes no way in). The shortcuts and the search field above it are
        // fixed for the same reason, which is why the whole block can be
        // measured rather than guessed at.
        .presentationDetents([.height(Self.sheetHeight)])
        .presentationDragIndicator(.visible)
    }
}
