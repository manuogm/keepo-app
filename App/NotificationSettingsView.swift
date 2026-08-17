import SwiftUI
import UIKit
import UserNotifications

/// Three levels (spec): no notifications; functional only (automatic
/// payment capture + items needing review — gated in `CaptureIntent`);
/// full experience (functional, plus a monthly balance check-in reminder
/// scheduled/cancelled here via `BalanceReminderScheduler`).
///
/// The one place system notification permission is ever requested — not
/// onboarding, not `CaptureIntent` (an App Intent has no business
/// interrupting a Wallet automation with a permission sheet), and not
/// merely opening this screen either — only the deliberate act of tapping
/// "Functional Only" or "Full Experience" asks.
///
/// No app can flip iOS's own notification toggle, in either direction —
/// once the user has answered the system dialog once, `requestAuthorization`
/// silently returns that same answer forever after, never re-prompting
/// (the entire point of "Don't Allow" meaning something). `.denied` is the
/// one state this screen can't fix from inside the app, so it offers the
/// next best thing instead: a direct jump to Keepo's own Settings page via
/// `openSettingsURLString`, where the user can flip it themselves.
struct NotificationSettingsView: View {
    @AppStorage(AppSettingsKeys.notificationLevel) private var level = NotificationLevel.full
    @State private var showPermissionDeniedAlert = false

    var body: some View {
        Form {
            Section {
                ForEach(NotificationLevel.allCases, id: \.self) { option in
                    Button {
                        level = option
                        Task { await sync(option) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                    .foregroundStyle(Color.primary)
                                Text(option.detail)
                                    .font(.footnote)
                                    .foregroundStyle(Color.secondary)
                            }
                            Spacer()
                            if level == option {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.primary)
                            }
                        }
                    }
                }
            } footer: {
                Text("Wallet-automation captures always land in Needs Review even when notifications are off.")
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Notifications Are Off", isPresented: $showPermissionDeniedAlert) {
            Button("Open Settings") { openSystemSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keepo needs permission in iPhone Settings before it can send notifications.")
        }
    }

    private func sync(_ level: NotificationLevel) async {
        if level != .none {
            let center = UNUserNotificationCenter.current()
            switch await center.notificationSettings().authorizationStatus {
            case .notDetermined:
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            case .denied:
                showPermissionDeniedAlert = true
            default:
                break
            }
        }
        if level == .full {
            await BalanceReminderScheduler.schedule()
        } else {
            BalanceReminderScheduler.cancel()
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
