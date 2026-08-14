import SwiftUI

/// Small, calm, and persistent — replaces the per-screen red "you appear to
/// be offline" error text with one ambient indicator shown from RootView.
/// Being offline isn't a per-action failure worth alarming red text; it's
/// ongoing state, and the user should only need to be told once, in one
/// place, for as long as it's true. Tappable — opens `OfflineInfoSheet` with
/// a reminder of what still works.
struct OfflineStatusBar: View {
    let lastSyncedAt: Date?
    @State private var showInfo = false

    var body: some View {
        Button {
            showInfo = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "wifi.slash")
                Text("You are offline")
                if let lastSyncedAt {
                    Text("· Last synced \(lastSyncedAt.formatted(.relative(presentation: .named)))")
                }
            }
            .font(.caption2)
            .foregroundStyle(Color.red.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showInfo) {
            OfflineInfoSheet()
        }
    }
}

#Preview {
    OfflineStatusBar(lastSyncedAt: .now.addingTimeInterval(-3600))
}
