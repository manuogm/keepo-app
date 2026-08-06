import KeepoCore
import SwiftUI

/// One inbox, one renderer switching on `item.kind` — `needs_review`'s
/// stable column contract (kind, item_id, account_id, occurred_at, title,
/// subtitle, amount, currency) means a later phase's new branch (Phase
/// 12/14/18/19) needs no change here at all, only a new `case` in
/// `NeedsReviewRow`'s icon/action switch.
struct NeedsReviewView: View {
    let session: SessionStore

    @State private var store = DataStore<PublicSchema.NeedsReviewSelect>()
    @State private var currencyMinorUnits: [String: Int] = [:]
    @State private var actionErrorMessage: String?

    var body: some View {
        ZStack {
            Color("BGCanvas").ignoresSafeArea()

            if store.isLoading {
                ProgressView()
            } else if store.items.isEmpty {
                Text("Nothing needs review")
                    .foregroundStyle(Color("TextSecondary"))
            } else {
                List {
                    ForEach(store.items, id: \.itemId) { item in
                        row(item)
                    }
                }
                .scrollContentBackground(.hidden)
                .refreshable { await load() }
            }

            if let errorMessage = store.errorMessage ?? actionErrorMessage {
                VStack {
                    Spacer()
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                }
            }
        }
        .navigationTitle("Needs Review")
        .task(id: session.refresh.token) { await load() }
    }

    @ViewBuilder
    private func row(_ item: PublicSchema.NeedsReviewSelect) -> some View {
        Group {
            if item.kind == "reconciliation_gap" {
                NavigationLink {
                    SyncRitualView(session: session)
                } label: {
                    NeedsReviewRow(item: item, minorUnit: minorUnit(for: item.currency))
                }
            } else {
                NeedsReviewRow(item: item, minorUnit: minorUnit(for: item.currency))
            }
        }
        .swipeActions(edge: .trailing) {
            if item.kind == "sync_conflict" {
                Button("Resolve") {
                    Task { await resolve(item) }
                }
                .tint(Color("BrandPrimary"))
            }
        }
    }

    private func minorUnit(for currencyCode: String?) -> Int {
        guard let currencyCode else { return 2 }
        return currencyMinorUnits[currencyCode] ?? 2
    }

    private func load() async {
        if currencyMinorUnits.isEmpty {
            let currencies = (try? await CurrencyRepository.fetchAll(client: session.client)) ?? []
            currencyMinorUnits = Dictionary(uniqueKeysWithValues: currencies.map { ($0.code, Int($0.minorUnit)) })
        }
        await store.load { try await NeedsReviewRepository.fetchAll(client: session.client) }
    }

    private func resolve(_ item: PublicSchema.NeedsReviewSelect) async {
        guard let id = item.itemId else { return }
        actionErrorMessage = nil
        do {
            try await NeedsReviewRepository.resolveSyncConflict(client: session.client, id: id)
            session.refresh.bump()
        } catch {
            actionErrorMessage = String(describing: error)
        }
    }
}

private struct NeedsReviewRow: View {
    let item: PublicSchema.NeedsReviewSelect
    let minorUnit: Int

    var body: some View {
        HStack {
            Image(systemName: iconName)
                .foregroundStyle(Color("BrandSecondary"))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title ?? "—")
                    .foregroundStyle(Color("TextPrimary"))
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color("TextSecondary"))
                }
            }
            Spacer()
            if let amount = item.amount, let currencyCode = item.currency {
                Text(MoneyFormatter.format(amount, currency: CurrencyInfo(code: currencyCode, minorUnit: minorUnit)))
                    .monospacedDigit()
                    .foregroundStyle(Color("BrandPrimary"))
            }
        }
    }

    private var iconName: String {
        switch item.kind {
        case "sync_conflict": return "exclamationmark.arrow.triangle.2.circlepath"
        case "reconciliation_gap": return "arrow.triangle.2.circlepath"
        default: return "questionmark.circle"
        }
    }
}
