import KeepoCore
import Supabase
import SwiftUI

struct DataPrivacyView: View {
    let session: SessionStore

    @State private var isSyncingFX = false
    @State private var fxSyncMessage: String?
    @State private var lastSyncedAt: Date?
    @State private var showDeleteConfirmation = false
    @State private var isDeletingAccount = false
    @State private var deleteErrorMessage: String?

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            List {
                Section {
                    NavigationLink("Import CSV") {
                        CSVImportView(session: session)
                    }
                    NavigationLink("Export") {
                        ExportView(session: session)
                    }
                    NavigationLink("Archived") {
                        ArchiveAccountsView(session: session)
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Bring in a bank statement or take everything with you.")
                }

                Section {
                    Button {
                        Task { await syncFXRates() }
                    } label: {
                        HStack {
                            if isSyncingFX {
                                ProgressView().id("fx-sync-spinner")
                            } else {
                                Text("Sync Exchange Rates")
                            }
                            Spacer()
                            if let lastSyncedAt {
                                let relative = Self.relativeFormatter.localizedString(
                                    for: lastSyncedAt, relativeTo: Date()
                                )
                                Text("Last synced \(relative)")
                                    .font(.footnote)
                                    .foregroundStyle(Color.secondary)
                            }
                        }
                    }
                    .foregroundStyle(Color.primary)
                    .disabled(isSyncingFX)
                    if let fxSyncMessage {
                        Text(fxSyncMessage)
                            .font(.footnote)
                            .foregroundStyle(
                                fxSyncMessage.hasPrefix("Failed")
                                    ? Color.red
                                    : Color.secondary
                            )
                    }
                } footer: {
                    Text("Pulls the latest exchange rates so balances convert correctly.")
                }

                Section {
                    NavigationLink("Security") {
                        SecuritySettingsView(session: session)
                    }
                } footer: {
                    Text("Biometric step-up and recovery identity settings.")
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        HStack {
                            Text("Delete Account")
                            Spacer()
                            if isDeletingAccount {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isDeletingAccount)
                    if let deleteErrorMessage {
                        Text(deleteErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text("Permanently deletes your account and all financial data. This cannot be undone.")
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
        .navigationTitle("Data & Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadLastSyncedAt() }
        .confirmationDialog(
            "Delete your account?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Account", role: .destructive) {
                Task { await deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This permanently deletes all your financial data, accounts, and transactions. "
                    + "You will be signed out immediately. This cannot be undone."
            )
        }
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
            fxSyncMessage = "Exchange rates synced."
            session.refresh.bump()
            await loadLastSyncedAt()
        } catch {
            fxSyncMessage = "Failed: \(UserFacingError.describe(error))"
        }
        isSyncingFX = false
    }

    private func loadLastSyncedAt() async {
        lastSyncedAt = try? await FxRateRepository.latestFetchedAt(client: session.client)
    }

    private func deleteAccount() async {
        isDeletingAccount = true
        deleteErrorMessage = nil
        do {
            try await session.stepUp(reason: "Confirm account deletion")
            try await session.deleteAccount()
        } catch {
            deleteErrorMessage = UserFacingError.describe(error)
            isDeletingAccount = false
        }
    }
}
