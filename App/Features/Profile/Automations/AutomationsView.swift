import KeepoCore
import SwiftUI

struct AutomationsView: View {
    let session: SessionStore

    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()
            List {
                // One section, not two. They were split only so each could
                // carry its own explanatory footer; with the footers gone
                // the split was two rows pretending to be two topics.
                Section {
                    NavigationLink {
                        RecurringRulesView(session: session)
                    } label: {
                        ProfileRowLabel(icon: "icon-recurrent", title: "Recurring Transactions")
                    }

                    NavigationLink {
                        WalletAutomationGuideView(session: session)
                    } label: {
                        ProfileRowLabel(icon: "icon-tap", title: "Set Up Apple Pay Capture")
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("My Automations")
        .navigationBarTitleDisplayMode(.inline)
    }
}
