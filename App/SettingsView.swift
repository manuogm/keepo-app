import KeepoCore
import SwiftUI

/// Phase 19 moved the household section to its own screen (`HouseholdView`,
/// reached below) — invites/leave/erase gave it enough of its own concerns
/// to no longer fit inline here, the same "not every feature is a tab"
/// reasoning Recurring/Budgets/Security already followed.
struct SettingsView: View {
    let session: SessionStore

    var body: some View {
        ZStack {
            Color("BGCanvas").ignoresSafeArea()

            List {
                Section {
                    NavigationLink("Household") {
                        HouseholdView(session: session)
                    }
                } footer: {
                    Text("Invite a partner, share accounts, or leave — your data is always yours to take with you.")
                }

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

                Section {
                    NavigationLink("Import CSV") {
                        CSVImportView(session: session)
                    }
                    NavigationLink("Export") {
                        ExportView(session: session)
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Bring in a bank statement, or take everything with you.")
                }

                Section {
                    NavigationLink("Security") {
                        SecuritySettingsView(session: session)
                    }
                } footer: {
                    Text("Base currency, biometric step-up, and a recovery email.")
                }

                #if DEBUG
                Section("Developer") {
                    NavigationLink("Simulate Capture") {
                        SimulateCaptureView(session: session)
                    }
                }
                #endif
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Settings")
    }
}
