import SwiftUI

/// One place for the Wallet-automation setup copy — shown once at the end
/// of onboarding and again anytime from Settings, since the automation
/// must be built by the user in the Shortcuts app; Keepo can only guide it
/// (spec: "Known limitations, accepted" — the app cannot install it).
struct WalletAutomationGuideView: View {
    var body: some View {
        List {
            Section {
                Text(
                    "Keepo can log Apple Pay purchases automatically, but the automation itself lives in "
                        + "Apple's Shortcuts app — this is a one-time setup."
                )
                .foregroundStyle(Color.secondary)
            }

            Section("Setup") {
                step(1, "Open Shortcuts → Automation → New Automation → Wallet.")
                step(2, "Choose the card to capture, then \"Any Transaction Amount.\"")
                step(3, "Add an action → Keepo → \"Log Apple Pay Purchase.\"")
                step(4, "Turn off \"Ask Before Running\" so it captures silently.")
                step(5, "In Keepo, map the card to an account from Needs Review after its first purchase.")
            }

            Section {
                Text(
                    "Apple Pay only, on this device — closed-loop apps (like Walmart Pay) never touch Wallet "
                        + "and can't trigger this automation."
                )
                .font(.footnote)
                .foregroundStyle(Color.secondary)
            }
        }
        .navigationTitle("Apple Pay Capture")
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.footnote).fontWeight(.semibold)
                .foregroundStyle(Color.primary)
            Text(text)
                .foregroundStyle(Color.primary)
        }
    }
}
