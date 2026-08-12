import SwiftUI

/// Small, calm, and persistent — replaces the per-screen red "you appear to
/// be offline" error text with one ambient indicator shown from RootView,
/// laid directly over the tab bar on every tab (no background of its own,
/// so the tab bar renders normally underneath). Being offline isn't a
/// per-action failure worth alarming red text; it's ongoing state, and the
/// user should only need to be told once, in one place, for as long as
/// it's true.
struct OfflineStatusBar: View {
    let lastSyncedAt: Date?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
            Text("You are offline")
            if let lastSyncedAt {
                Text("· Last synced \(lastSyncedAt.formatted(.relative(presentation: .named)))")
            }
        }
        .font(.caption2)
        .foregroundStyle(Color.secondary)
    }
}

#Preview {
    OfflineStatusBar(lastSyncedAt: .now.addingTimeInterval(-3600))
}
