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
                    Image(systemName: "chevron.right")
                        .font(AppTheme.Typography.nanoEmphasis)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                }
            }

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.Spacing.m)
        .background(
            AppTheme.Palette.bgSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card)
        )
    }
}

/// The base-currency picker, as a sheet rather than the inline `Picker` row
/// it replaces.
///
/// A `Picker` in a `List` renders its options as a pushed screen of plain
/// three-letter codes — no flags, no names — which is a worse list than the
/// app already draws for currencies everywhere else. This is the same
/// `CurrencyBadge` row the account form's own picker uses.
struct BaseCurrencySheet: View {
    let currencies: [PublicSchema.CurrenciesSelect]
    @Binding var selection: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.Palette.bgCanvas.ignoresSafeArea()
                List {
                    ForEach(currencies, id: \.code) { currency in
                        Button {
                            selection = currency.code
                            dismiss()
                        } label: {
                            HStack(spacing: AppTheme.Spacing.m) {
                                CurrencyBadge(code: currency.code, diameter: AppTheme.Size.glyph)
                                Spacer()
                                if currency.code == selection {
                                    Image(systemName: "checkmark")
                                        .font(AppTheme.Typography.labelEmphasis)
                                        .foregroundStyle(AppTheme.Palette.brandPrimary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Base Currency")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
        }
    }
}
