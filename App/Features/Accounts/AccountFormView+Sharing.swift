import KeepoCore
import SwiftUI

// The account form's household sharing controls, split out of
// AccountFormView.swift for the project's type-body-length lint — same
// precedent as AccountFormView+Dialogs.swift. Nothing here is `private` for
// that reason alone.

extension AccountFormView {
    /// Sharing is the one control here that is not offline-capable and not
    /// symmetrical. Turning it on asks how much history to share; turning it
    /// off hands the other member a copy of what they could see
    /// (20261012100000), so it is not an undo, and it says so before it
    /// happens.
    ///
    /// Only the owner gets the switch. `unshare_account` refuses anyone
    /// else, so on the partner's phone a switch could only fail — they are
    /// told where the account stands instead.
    @ViewBuilder
    var shareToggleRow: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            if isOwner {
                Toggle("Share with Household", isOn: shareBinding)
                    .tint(AppTheme.Palette.statusPositive)
                    .disabled(!hasHousehold || isSaving)
                if !hasHousehold {
                    shareNote("Create a household in Profile first.")
                }
                if let sharedFromLabel {
                    shareNote("Your household sees its transactions from \(sharedFromLabel).")
                    Button("Include Past Transactions") { showIncludePast = true }
                        .font(AppTheme.Typography.microEmphasis)
                        .foregroundStyle(PublicSchema.AccountScope.household.tint)
                        .disabled(isSaving)
                }
            } else {
                Text("Shared with Household")
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                if let sharedFromLabel {
                    shareNote(
                        "Shared with you from \(sharedFromLabel). Earlier transactions stay private to its owner."
                    )
                } else {
                    shareNote("Shared with you by its owner.")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.Spacing.l)
        .padding(.vertical, AppTheme.Spacing.m)
    }

    private func shareNote(_ text: String) -> some View {
        Text(text)
            .font(AppTheme.Typography.micro)
            .foregroundStyle(AppTheme.Palette.textSecondary)
    }

    var shareBinding: Binding<Bool> {
        Binding(
            get: { isShared },
            set: { newValue in
                if newValue {
                    showShareChoice = true
                } else {
                    showUnshareConfirm = true
                }
            }
        )
    }
}
