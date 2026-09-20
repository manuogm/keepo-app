import SwiftUI
import UIKit
import UserNotifications

/// Three levels (spec): no notifications; functional only (automatic
/// payment capture + items needing review — gated in `CaptureIntent`);
/// full experience (functional, plus a monthly balance check-in reminder
/// scheduled/cancelled here via `BalanceReminderScheduler`).
///
/// System notification permission is requested here, on the deliberate act
/// of tapping "Functional Only" or "Full Experience". Never from
/// `CaptureIntent` — an App Intent has no business interrupting a Wallet
/// automation with a permission sheet.
///
/// Both this and setup step 4 go through `NotificationPermission`, which
/// is the only place in the app that calls `requestAuthorization` — iOS
/// asks exactly once ever, so a second call site is not a second chance,
/// it is a call that looks like it did something and did not. Setup does
/// the real ask, primed and behind an explicit button; this one is the
/// defensive repeat for a returning user who never saw setup.
///
/// No app can flip iOS's own notification toggle, in either direction —
/// once the user has answered the system dialog once, `requestAuthorization`
/// silently returns that same answer forever after, never re-prompting
/// (the entire point of "Don't Allow" meaning something). `.denied` is the
/// one state this screen can't fix from inside the app, so it surfaces it
/// up front (not just when a level is tapped) with a direct jump to
/// Keepo's own Settings page via `openSettingsURLString`.
struct NotificationSettingsView: View {
    @AppStorage(AppSettingsKeys.notificationLevel) private var level = NotificationLevel.full
    @State private var showPermissionDeniedAlert = false
    @State private var isSystemPermissionDenied = false
    @Environment(\.colorScheme) private var colorScheme

    /// The selected card's fill is `textPrimary` itself, which is adaptive
    /// — so its own text cannot reuse that token without disappearing into
    /// it. `inkOnPrimaryFill` is that pair, in one place.
    private var selectedTextColor: Color {
        AppTheme.Palette.inkOnPrimaryFill(colorScheme)
    }

    var body: some View {
        Form {
            if isSystemPermissionDenied {
                Section {
                    Button("Notifications are off in iPhone Settings — tap to fix") { openSystemSettings() }
                        .foregroundStyle(AppTheme.Palette.statusNegative)
                }
            }
            Section {
                ForEach(NotificationLevel.allCases, id: \.self) { option in
                    let isSelected = level == option
                    Button {
                        level = option
                        Task { await sync(option) }
                    } label: {
                        HStack(spacing: AppTheme.Spacing.s) {
                            KeepoIcon(name: option.icon, size: AppTheme.Size.icon)
                                .foregroundStyle(isSelected ? selectedTextColor : AppTheme.Palette.textPrimary)
                                .frame(width: AppTheme.Size.touchTarget, height: AppTheme.Size.touchTarget)
                                .accessibilityHidden(true)
                            // A hidden twin sized for the longest possible
                            // detail (two lines) reserves one consistent
                            // height for every card. The real title+detail
                            // block — one line of detail for "No
                            // Notifications", two for the others — centers
                            // as a whole inside that reserved height, so
                            // every card gets the same top/bottom margin
                            // without disturbing the title-to-detail gap
                            // that separates its own two lines.
                            ZStack(alignment: .leading) {
                                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                                    Text(option.label)
                                        .font(AppTheme.Typography.bodyEmphasis)
                                        .lineLimit(1)
                                    Text("Reserved\nReserved")
                                        .font(AppTheme.Typography.caption)
                                        .lineLimit(2)
                                }
                                .opacity(0)
                                .accessibilityHidden(true)

                                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                                    Text(option.label)
                                        .font(isSelected ? AppTheme.Typography.bodyEmphasis : AppTheme.Typography.body)
                                        .foregroundStyle(isSelected ? selectedTextColor : AppTheme.Palette.textPrimary)
                                        .lineLimit(1)
                                    Text(option.detail)
                                        .font(AppTheme.Typography.caption)
                                        .foregroundStyle(
                                            isSelected
                                                ? selectedTextColor.opacity(0.85)
                                                : AppTheme.Palette.textSecondary
                                        )
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                        }
                        .padding(AppTheme.Spacing.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            isSelected ? AppTheme.Palette.textPrimary : AppTheme.Palette.bgSurface,
                            in: RoundedRectangle(cornerRadius: AppTheme.Radius.card)
                        )
                    }
                    .buttonStyle(.pressableRow)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(
                        top: AppTheme.Spacing.s, leading: AppTheme.Spacing.l,
                        bottom: AppTheme.Spacing.s, trailing: AppTheme.Spacing.l
                    ))
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshSystemPermissionState() }
        .alert("Notifications Are Off", isPresented: $showPermissionDeniedAlert) {
            Button("Open Settings") { openSystemSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keepo needs permission in iPhone Settings before it can send notifications.")
        }
    }

    private func refreshSystemPermissionState() async {
        isSystemPermissionDenied = await NotificationPermission.status() == .denied && level != .none
    }

    private func sync(_ level: NotificationLevel) async {
        if level != .none, await NotificationPermission.requestIfNeeded() == .denied {
            showPermissionDeniedAlert = true
        }
        await refreshSystemPermissionState()
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
