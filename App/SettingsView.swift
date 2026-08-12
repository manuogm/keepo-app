import KeepoCore
import Supabase
import SwiftUI

/// Phase 19 moved the household section to its own screen (`HouseholdView`,
/// reached below) — invites/leave/erase gave it enough of its own concerns
/// to no longer fit inline here, the same "not every feature is a tab"
/// reasoning Recurring/Budgets/Security already followed.
struct SettingsView: View {
    let session: SessionStore

    @State private var isSyncingFX = false
    @State private var fxSyncMessage: String?

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

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
                    Button {
                        Task { await syncFXRates() }
                    } label: {
                        HStack {
                            if isSyncingFX {
                                ProgressView().id("fx-sync-spinner")
                            } else {
                                Text("Sync FX Rates")
                            }
                        }
                    }
                    .disabled(isSyncingFX)
                    if let fxSyncMessage {
                        Text(fxSyncMessage)
                            .font(.footnote)
                            .foregroundStyle(
                                fxSyncMessage.starts(with: "Sync failed")
                                    ? Color.red
                                    : Color.secondary
                            )
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text(
                        "Bring in a bank statement, or take everything with you. "
                            + "Sync pulls the latest exchange rates so balances convert correctly."
                    )
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
        .navigationBarTitleDisplayMode(.inline)
    }

    private func syncFXRates() async {
        isSyncingFX = true
        fxSyncMessage = nil
        do {
            struct SyncBody: Encodable { let days: Int }
            try await session.client.functions.invoke(
                "sync-fx-rates",
                options: FunctionInvokeOptions(body: SyncBody(days: 400))
            )
            fxSyncMessage = "FX rates synced."
            session.refresh.bump()
        } catch {
            fxSyncMessage = "Sync failed: \(UserFacingError.describe(error))"
        }
        isSyncingFX = false
    }
}
