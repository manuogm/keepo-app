import KeepoCore
import SwiftUI

/// UI labels are "Everyday" and "Investments" — `valuation` never appears in
/// the interface, per keepo-v1-feature-spec.md §Accounts & Multi-Currency.
struct AccountsListView: View {
    let session: SessionStore

    @State private var accounts: [PublicSchema.AccountsWithBalancesSelect] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var everyday: [PublicSchema.AccountsWithBalancesSelect] {
        accounts.filter { $0.kind == .ledger }
    }

    private var investments: [PublicSchema.AccountsWithBalancesSelect] {
        accounts.filter { $0.kind == .valuation }
    }

    var body: some View {
        ZStack {
            Color("BGCanvas").ignoresSafeArea()

            if isLoading {
                ProgressView()
            } else {
                List {
                    if !everyday.isEmpty {
                        Section("Everyday") {
                            ForEach(everyday, id: \.accountId) { account in
                                AccountRow(account: account)
                            }
                        }
                    }
                    if !investments.isEmpty {
                        Section("Investments") {
                            ForEach(investments, id: \.accountId) { account in
                                AccountRow(account: account)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }

            if let errorMessage {
                VStack {
                    Spacer()
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                }
            }
        }
        .navigationTitle("Accounts")
        .task { await load() }
    }

    private func load() async {
        do {
            accounts = try await AccountRepository.fetchAllWithBalances(client: session.client)
        } catch {
            errorMessage = String(describing: error)
        }
        isLoading = false
    }
}

private struct AccountRow: View {
    let account: PublicSchema.AccountsWithBalancesSelect

    var body: some View {
        HStack {
            Text(account.name ?? "—")
                .foregroundStyle(Color("TextPrimary"))
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                // Balance and currency both come from the row — MoneyFormatter
                // is the one place amounts render, per CLAUDE.md's Engineering
                // Principles. A nil balance (e.g. an unsnapshotted valuation
                // account) renders as "—", never "0" (money rule 5).
                Text(formattedBalance)
                    .monospacedDigit()
                    .foregroundStyle(Color("BrandPrimary"))
                CurrencyConversionLabel(
                    nativeCurrency: account.currency,
                    amountBase: account.balanceBase,
                    baseCurrency: account.baseCurrency,
                    baseMinorUnit: account.baseMinorUnit,
                    hasMissingRate: account.hasMissingRate ?? false
                )
            }
        }
    }

    private var formattedBalance: String {
        guard let currencyCode = account.currency, let minorUnit = account.minorUnit else { return "—" }
        let currency = CurrencyInfo(code: currencyCode, minorUnit: Int(minorUnit))
        return MoneyFormatter.format(account.balance, currency: currency)
    }
}
