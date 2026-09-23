import KeepoCore
import SwiftUI

// The Export screen's building blocks, split out of ExportView+Steps.swift for
// the project's file-length lint: the period page's quick-pick pill, the last
// page's recap row, and the carried-filter chip.

/// A quick pick over the period calendar — "This month", "Last 12 months".
/// Filled when the calendar's days are exactly that preset's, with the same
/// ink-on-primary treatment the calendar's own endpoints use, so the pill and
/// the range it drew read as one answer.
struct ExportPeriodPill: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AppTheme.Typography.label)
                .foregroundStyle(
                    isSelected ? AppTheme.Palette.inkOnPrimaryFill(colorScheme) : AppTheme.Palette.textPrimary
                )
                .padding(.horizontal, AppTheme.Spacing.m)
                .padding(.vertical, AppTheme.Spacing.s)
                .background(isSelected ? AppTheme.Palette.textPrimary : AppTheme.Palette.fillSubtle, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.pressableCard)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .sensoryFeedback(AppTheme.Feedback.selection, trigger: isSelected)
    }
}

/// One earlier answer on the last page — "Period: Last month, August 2026"
/// — and the way back to change it.
struct ExportRecapRow: View {
    let title: String
    let value: String
    var detail: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.m) {
                Text(title)
                    .font(AppTheme.Typography.label)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                Spacer(minLength: AppTheme.Spacing.s)
                VStack(alignment: .trailing, spacing: AppTheme.Spacing.xxs) {
                    Text(value)
                        .font(AppTheme.Typography.labelEmphasis)
                        .foregroundStyle(AppTheme.Palette.textPrimary)
                    if let detail {
                        Text(detail)
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                    }
                }
                .multilineTextAlignment(.trailing)
                Image(systemName: "chevron.right")
                    .font(AppTheme.Typography.captionEmphasis)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            }
            .padding(.vertical, AppTheme.Spacing.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableCard)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Goes back to change it")
    }
}

/// A filter the export is carrying over, with the way to drop it.
struct ExportFilterChip: View {
    let title: String
    let onRemove: () -> Void

    var body: some View {
        Button(action: onRemove) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text(title)
                    .font(AppTheme.Typography.label)
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(AppTheme.Typography.nanoEmphasis)
            }
            .foregroundStyle(AppTheme.Palette.textPrimary)
            .padding(.horizontal, AppTheme.Spacing.m)
            .padding(.vertical, AppTheme.Spacing.s)
            .background(AppTheme.Palette.fillSubtle, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.pressableCard)
        .accessibilityLabel("Remove filter \(title)")
    }
}
