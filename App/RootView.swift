import KeepoCore
import SwiftUI

/// Scaffold placeholder — proves the asset catalog's brand Color Sets and the
/// KeepoCore money formatter are wired correctly. Replaced once real screens land.
struct RootView: View {
    private let sampleBalance = MoneyFormatter.format(
        Decimal(string: "12480.50"),
        currency: CurrencyInfo(code: "USD", minorUnit: 2)
    )

    var body: some View {
        ZStack {
            Color("BGCanvas").ignoresSafeArea()

            VStack(spacing: 16) {
                Text("Keepo")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundStyle(Color("TextPrimary"))

                Text(sampleBalance)
                    .font(.largeTitle)
                    .fontWeight(.heavy)
                    .monospacedDigit()
                    .foregroundStyle(Color("BrandPrimary"))

                Text("Scaffold build — screens land here")
                    .font(.callout)
                    .foregroundStyle(Color("TextSecondary"))
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color("BGSurface"))
            )
            .padding()
        }
    }
}

#Preview {
    RootView()
}
