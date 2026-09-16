import KeepoCore
import SwiftUI

/// One spinning wheel of currencies, and nothing else.
///
/// Extracted from `BaseCurrencySheet` so the sheet on My Profile and
/// onboarding's inline currency step render **one** implementation. They
/// are the same question asked in two places, and the sizing below is the
/// part that would have been got wrong twice.
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

    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(currencies, id: \.code) { currency in
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
    }
}
