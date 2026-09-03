import KeepoCore
import SwiftUI

struct PreferencesView: View {
    let session: SessionStore

    @State private var currencies: [PublicSchema.CurrenciesSelect] = []
    @State private var selectedCurrency = ""
    @State private var isSavingCurrency = false
    @State private var errorMessage: String?
    @AppStorage(AppSettingsKeys.appearanceMode) private var appearanceMode = AppearanceMode.system

    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()
            List {
                Section {
                    Picker("Base Currency", selection: $selectedCurrency) {
                        ForEach(currencies, id: \.code) { currency in
                            Text(currency.code).tag(currency.code)
                        }
                    }
                    .onChange(of: selectedCurrency) { oldValue, newValue in
                        guard oldValue != newValue, !oldValue.isEmpty else { return }
                        Task { await saveBaseCurrency() }
                    }
                    if isSavingCurrency {
                        ProgressView()
                    }
                    if let errorMessage {
                        FormErrorText(message: errorMessage)
                    }
                } footer: {
                    Text("Every balance and chart converts into your chosen base currency.")
                }

                Section {
                    Picker("Appearance", selection: $appearanceMode) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    NavigationLink("Notifications") {
                        NotificationSettingsView()
                    }
                } header: {
                    Text("Display")
                } footer: {
                    Text("Appearance applies to Keepo only, independent of your iOS system setting.")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Preferences")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        currencies = (try? await session.dbQueue.read { database in try LocalTableQueries.currencies(database) }) ?? []
        selectedCurrency = session.profile?.baseCurrency ?? currencies.first?.code ?? "USD"
    }

    private func saveBaseCurrency() async {
        guard let userId = session.profile?.id else { return }
        isSavingCurrency = true
        errorMessage = nil
        do {
            try await ProfileRepository.updateBaseCurrency(
                client: session.client, userId: userId, baseCurrency: selectedCurrency
            )
            try await session.refreshProfile()
            session.refresh.bump()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isSavingCurrency = false
    }
}
