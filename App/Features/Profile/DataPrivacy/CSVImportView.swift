import KeepoCore
import SwiftUI
import UniformTypeIdentifiers

/// Phase 18: CSV import. Pick an account, pick a file, review the parsed
/// rows, submit — matching (exact amount, +/-3 days, same account) happens
/// server-side (`import_csv_rows`); this screen never decides a row is a
/// duplicate on its own, it only surfaces what the RPC already found and
/// routes the rest to Needs Review for accept/reject.
struct CSVImportView: View {
    let session: SessionStore

    @State private var accounts: [LocalAccountRow] = []
    @State private var selectedAccountId: UUID?
    @State private var isPickingFile = false
    @State private var filename: String?
    @State private var parsedRows: [CSVImportRow] = []
    @State private var isImporting = false
    @State private var resultMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Account") {
                Picker("Import into", selection: $selectedAccountId) {
                    Text("Choose an account").tag(UUID?.none)
                    ForEach(importableAccounts) { account in
                        Text(account.name).tag(UUID?.some(account.id))
                    }
                }
            }

            Section {
                Button {
                    isPickingFile = true
                } label: {
                    Text(filename ?? "Choose CSV File")
                }
                if !parsedRows.isEmpty {
                    Text("\(parsedRows.count) row(s) parsed")
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                }
            } header: {
                Text("Statement")
            } footer: {
                Text("Every row becomes a review candidate — nothing is inserted until you accept it.")
            }

            if !parsedRows.isEmpty {
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isImporting {
                            ProgressView()
                        } else {
                            Text("Import \(parsedRows.count) Row(s)")
                        }
                    }
                    .disabled(isImporting || selectedAccountId == nil)
                }
            }

            if let resultMessage {
                Text(resultMessage).foregroundStyle(Color.primary)
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
        .navigationTitle("Import CSV")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let ownerId = session.profile?.id, let baseCurrency = session.profile?.baseCurrency else { return }
            accounts = (try? await session.dbQueue.read { database in
                try LocalAccountRow.fetchAll(database, ownerId: ownerId.uuidString, baseCurrency: baseCurrency)
            }) ?? []
        }
        .fileImporter(isPresented: $isPickingFile, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            handlePickedFile(result)
        }
    }

    private var importableAccounts: [LocalAccountRow] {
        accounts.filter { $0.archivedAt == nil }
    }

    private func handlePickedFile(_ result: Result<URL, Error>) {
        errorMessage = nil
        resultMessage = nil
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let contents = try String(contentsOf: url, encoding: .utf8)
            parsedRows = try CSVImportParser.parse(contents)
            filename = url.lastPathComponent
        } catch {
            parsedRows = []
            errorMessage = UserFacingError.describe(error)
        }
    }

    private func submit() async {
        guard let selectedAccountId else { return }
        let currency = accounts.first { $0.id == selectedAccountId }?.currency ?? "USD"
        isImporting = true
        errorMessage = nil
        do {
            let candidates = try await ImportRepository.importRows(
                client: session.client,
                accountId: selectedAccountId,
                filename: filename ?? "import.csv",
                rows: parsedRows,
                currency: currency
            )
            resultMessage = "Imported \(candidates.count) row(s) — review them in Needs Review."
            parsedRows = []
            filename = nil
            session.refresh.bump()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isImporting = false
    }
}
