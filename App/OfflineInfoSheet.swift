import SwiftUI

/// Tapped from `OfflineStatusBar` — a reminder of what still works while
/// offline, grouped by how well it works, so there are no surprises.
struct OfflineInfoSheet: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label("You're offline", systemImage: "wifi.slash")
                        .font(.headline)
                    Text(
                        "Changes you make now are saved on this device and sync automatically "
                            + "once you're back online."
                    )
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    group(
                        title: "Works offline",
                        icon: "checkmark.circle.fill",
                        color: .green,
                        items: [
                            "Viewing accounts, transactions, and balances",
                            "Adding, editing, and deleting transactions",
                            "Adding, editing, and archiving accounts",
                            "Adding and editing categories"
                        ]
                    )
                    group(
                        title: "Needs a connection",
                        icon: "exclamationmark.triangle.fill",
                        color: .orange,
                        items: [
                            "Deleting a category",
                            "Reviewing Apple Pay captures",
                            "Importing or exporting CSV files",
                            "Resolving a sync conflict"
                        ]
                    )
                    group(
                        title: "Unavailable offline",
                        icon: "xmark.circle.fill",
                        color: .red,
                        items: [
                            "Signing in for the first time",
                            "Household invites, accepting, or leaving",
                            "Refreshing exchange rates",
                            "Exporting data"
                        ]
                    )
                }
                .padding()
            }
            .navigationTitle("Offline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
    }

    private func group(title: String, icon: String, color: Color, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { item in
                    Label(item, systemImage: icon)
                        .font(.footnote)
                        .foregroundStyle(color)
                }
            }
        }
    }
}

#Preview {
    OfflineInfoSheet()
}
