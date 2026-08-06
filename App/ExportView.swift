import KeepoCore
import SwiftUI

/// Phase 18: export. Step-up re-auth runs immediately before generation
/// (spec: "the highest-value target in the app"), and `logExport` writes
/// the audit row right after the CSV is actually built — the export itself
/// can't be undone, but it can always be detected afterward.
struct ExportView: View {
    let session: SessionStore

    @State private var accounts: [PublicSchema.AccountsWithBalancesSelect] = []
    @State private var selectedAccountIds: Set<UUID> = []
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var exportedFileURL: URL?
    @State private var showShareSheet = false

    var body: some View {
        Form {
            Section {
                ForEach(accounts, id: \.accountId) { account in
                    if let accountId = account.accountId {
                        Toggle(account.name ?? "—", isOn: selectionBinding(for: accountId))
                    }
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text("Requires a fresh biometric check, and every export is logged.")
            }

            Section {
                Button {
                    Task { await export() }
                } label: {
                    if isExporting {
                        ProgressView()
                    } else {
                        Text("Export CSV")
                    }
                }
                .disabled(isExporting || selectedAccountIds.isEmpty)
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
        .navigationTitle("Export")
        .task {
            accounts = (try? await AccountRepository.fetchAllWithBalances(client: session.client)) ?? []
        }
        .sheet(isPresented: $showShareSheet) {
            if let exportedFileURL {
                ShareSheet(fileURL: exportedFileURL)
            }
        }
    }

    private func selectionBinding(for accountId: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedAccountIds.contains(accountId) },
            set: { newValue in
                if newValue { selectedAccountIds.insert(accountId) } else { selectedAccountIds.remove(accountId) }
            }
        )
    }

    private func export() async {
        isExporting = true
        errorMessage = nil
        do {
            try await session.stepUp(reason: "Confirm it's you to export your financial data")
            let accountIds = Array(selectedAccountIds)
            let rows = try await ExportRepository.fetchTransactions(client: session.client, accountIds: accountIds)
            let csv = ExportRepository.csv(from: rows)
            let url = try writeTempFile(csv)
            try await ExportRepository.logExport(client: session.client, accountIds: accountIds, rowCount: rows.count)
            exportedFileURL = url
            showShareSheet = true
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isExporting = false
    }

    private func writeTempFile(_ csv: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("keepo-export-\(UUID().uuidString).csv")
        try csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
