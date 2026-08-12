import SwiftUI

/// Three levels (spec): no notifications; functional only (automatic
/// payment capture + items needing review — gated in `CaptureIntent`);
/// full experience (functional, plus a monthly balance check-in reminder
/// scheduled/cancelled here via `BalanceReminderScheduler`).
struct NotificationSettingsView: View {
    @AppStorage(AppSettingsKeys.notificationLevel) private var level = NotificationLevel.full

    var body: some View {
        Form {
            Section {
                ForEach(NotificationLevel.allCases, id: \.self) { option in
                    Button {
                        level = option
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
        .onChange(of: level) { _, newLevel in
            Task {
                if newLevel == .full {
                    await BalanceReminderScheduler.schedule()
                } else {
                    BalanceReminderScheduler.cancel()
                }
            }
        }
    }
}
