import KeepoCore
import SwiftUI

// The "Mapped Cards" section, split out of AccountFormView.swift purely to
// keep that file under the project's file-length lint threshold — same
// precedent as TransactionFormView+Delete.swift.

extension AccountFormView {
    /// Always shown once editing, even with zero rows — a missing row
    /// would read as "unknown", not "none", and knowing there's nothing
    /// mapped is exactly what this row exists to answer at a glance.
    /// Tapping it pushes to `MappedCardsView`, which owns the actual
    /// add/rename/remove affordances.
    @ViewBuilder
    var mappedCardsSection: some View {
        if case .edit(let accountId) = mode {
            Section {
                NavigationLink {
                    MappedCardsView(session: session, accountId: accountId) {
                        Task { await loadCardMappings() }
                    }
                } label: {
                    HStack {
                        Text("Mapped Cards")
                        Spacer()
                        Text(cardMappings.isEmpty ? "None" : "\(cardMappings.count)")
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
    }

    func loadCardMappings() async {
        guard case .edit(let id) = mode, let ownerId = session.profile?.id else { return }
        cardMappings = (try? await session.dbQueue.read { database in
            try LocalTableQueries.cardMappings(database, accountId: id.uuidString, ownerId: ownerId.uuidString)
        }) ?? []
    }
}
