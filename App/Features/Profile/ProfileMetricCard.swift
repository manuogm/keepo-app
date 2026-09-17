import KeepoCore
import SwiftUI

/// A small titled card holding one fact about you.
///
/// Two of them sit side by side under the name on My Profile — when you
/// joined, and what currency you see your money in. Both were previously a
/// line of grey caption text and a `Picker` row buried in a settings list,
/// which is the wrong weight for either: the join date is a small piece of
/// pride and the base currency is the single setting that changes the meaning
/// of every number in the app.
///
/// The content is a slot rather than a string because the two are genuinely
/// different shapes — one is a date, the other a flag and a code — and
/// forcing them through one signature would mean an enum with two cases and
/// a `switch` in the middle of a card that is nine lines long.
struct ProfileMetricCard<Content: View>: View {
    let title: String
    /// Non-nil makes the whole card a button. The currency card is tappable
    /// and the membership card is not, and the difference has to be visible:
    /// a chevron appears only when there is somewhere to go.
    var action: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        if let action {
            Button(action: action) { card }
                .buttonStyle(.pressableCard)
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text(title)
                    .font(AppTheme.Typography.nano)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if action != nil {
                    Spacer(minLength: 0)
                    // `textTertiary`, not `textSecondary`: this card sits on
                    // My Profile directly above the row tiles below it (My
                    // Household, My Automations), whose chevron is `List`'s
                    // own system-drawn disclosure indicator — a lighter grey
                    // than every other manual chevron in the app uses.
                    Image(systemName: "chevron.right")
                        .font(AppTheme.Typography.nanoEmphasis)
                        .foregroundStyle(AppTheme.Palette.textTertiary)
                }
            }

            // Centred in whatever height is left under the title, not
            // pinned to the top of it. The two cards are the same height and
            // their titles are the same height, so the leftover rectangle is
            // identical in both — which makes "centred in it" the one rule
            // that puts a one-line currency badge and a two-line date on the
            // same axis, without either card knowing what the other holds.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        // Both axes, so a pair of these side by side is one pair of
        // identical rectangles whatever they contain: the width was always
        // shared, and the height now is too — the card takes all it is
        // offered and its caller decides how much that is.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(AppTheme.Spacing.m)
        .background(
            AppTheme.Palette.bgSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card)
        )
    }
}

/// The base-currency picker: one spinning wheel, dead centre of a half
/// sheet, and nothing else on it.
///
/// It was a scrolling `List` of tappable rows, which is the wrong shape for
/// this. Picking a base currency is choosing one value out of a fixed set —
/// the same job iOS gives a wheel everywhere it appears — and a list of
/// thirty near-identical rows makes the reader hunt through them, while a
/// wheel puts the current one under the finger and spins the rest past it.
/// The wheel itself is `CurrencyWheel`, shared with onboarding's currency
/// step — including the row-font sizing, whose reasoning lives there now.
///
/// The wheel writes to a **draft**, not straight through to the profile. A
/// wheel emits a selection for every currency it passes on the way to the
/// one you wanted, and each of those would have been a `PATCH`, a profile
/// refresh, and a full app-wide re-read. "Done" is what commits.
struct BaseCurrencySheet: View {
    let currencies: [PublicSchema.CurrenciesSelect]
    @Binding var selection: String

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
                    CurrencyWheel(currencies: currencies, selection: $draft, label: "Base Currency")
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
            .navigationTitle("Base Currency")
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
                    .accessibilityLabel("Set base currency")
                    .disabled(draft.isEmpty)
                }
            }
            // A profile with no base currency yet has nothing for the wheel
            // to land on, and an unmatched selection leaves it parked on the
            // first row while the binding still says "". Seeding from that
            // first row makes what the wheel shows and what "Done" would
            // write the same thing.
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
