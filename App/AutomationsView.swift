import KeepoCore
import SwiftUI

struct AutomationsView: View {
    let session: SessionStore

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            List {
                Section {
                    NavigationLink("Recurring Transactions") {
                        RecurringRulesView(session: session)
                    }
                } footer: {
                    Text("Rent, subscriptions, salary — anything on a schedule logs itself automatically.")
                }

                Section {
                    NavigationLink("Budgets") {
                        BudgetsView(session: session)
                    }
                } footer: {
                    Text("Set a monthly spending cap overall or per category.")
                }

                Section {
                    NavigationLink("Set Up Apple Pay Capture") {
                        WalletAutomationGuideView()
                    }
                } footer: {
                    Text("Log Apple Pay purchases automatically via a Shortcuts automation on the Wallet trigger.")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Automations")
    }
}
