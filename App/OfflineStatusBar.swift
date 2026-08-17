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

/// Shown instead of `OfflineStatusBar` when the device is online but a
/// write (most often a capture that queued while signed out or before the
/// owner's categories had synced — `Outbox.submitCaptureTransaction`'s rare
/// fallback) has been stuck in the outbox for a while, or the last sync
/// pull itself failed. Both `Outbox.drain`/`SyncEngine.pull` already retry
/// silently on every foreground/network-change/sign-in — the gap this
/// closes is that a *persistent* failure (not a one-off blip a retry
/// already fixes) previously had zero visible signal: `pendingCount` and
/// `lastErrorMessage` existed but nothing read them. Tapping retries both
/// immediately instead of waiting for the next passive trigger.
struct PendingSyncStatusBar: View {
    let pendingCount: Int
    let errorMessage: String?
    let retry: () async -> Void
    @State private var isRetrying = false

    var body: some View {
        Button {
            guard !isRetrying else { return }
            Task {
                isRetrying = true
                await retry()
                isRetrying = false
            }
        } label: {
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    if isRetrying {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(label)
                }
                // The reason, never just the count — a queue that only says
                // "3 waiting" and never why is exactly what hid a server-side
                // RPC mismatch through five rounds of testing.
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
            .font(.caption2)
            .foregroundStyle(Color.orange.opacity(0.9))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(isRetrying)
    }

    private var label: String {
        if pendingCount > 0 {
            return pendingCount == 1
                ? "1 purchase waiting to sync — tap to retry"
                : "\(pendingCount) purchases waiting to sync — tap to retry"
        }
        return "Sync failed — tap to retry"
    }
}

#Preview {
    PendingSyncStatusBar(
        pendingCount: 1, errorMessage: "Could not find the function public.capture_transaction", retry: {}
    )
}
