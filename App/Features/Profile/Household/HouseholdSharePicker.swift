import KeepoCore
import SwiftUI

// The pieces both halves of the invite flow are built from. Shared because
// the inviter and the invitee are answering the *same question* — "what of
// mine do you get to see?" — and a flow that asked it two different ways
// would read as two different features.

/// One thing you can offer, drawn the way the app draws things you tap.
///
/// The check sits on the trailing edge rather than as a leading control:
/// these rows are read as a list first and answered second, and a column of
/// empty boxes down the left turns a decision into a form.
struct ShareSelectionRow: View {
    let title: String
    let icon: String
    let tint: Color
    let isSelected: Bool
    /// "Matches your Groceries" — what will happen to this one, said before
    /// it happens rather than discovered afterwards.
    var detail: String?
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: AppTheme.Spacing.m) {
                Image(systemName: icon)
                    .font(AppTheme.Typography.microEmphasis)
                    .foregroundStyle(AppTheme.Palette.textOnAccent)
                    .frame(width: AppTheme.Size.icon, height: AppTheme.Size.icon)
                    .background(tint, in: Circle())

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(title)
                        .font(AppTheme.Typography.label)
                        .foregroundStyle(AppTheme.Palette.textPrimary)
                    if let detail {
                        Text(detail)
                            .font(AppTheme.Typography.micro)
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                    }
                }

                Spacer(minLength: AppTheme.Spacing.s)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(AppTheme.Typography.cardTitle)
                    .foregroundStyle(
                        isSelected ? AppTheme.Palette.statusPositive : AppTheme.Palette.fillStrong
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableRow)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// What this page is asking, and where it sits in the flow.
///
/// The dots are the whole reason this is a multi-page flow rather than one
/// long form: the answer to "how much more of this is there" has to be on
/// screen, or a two-question flow feels as open-ended as a ten-question one.
struct ShareStepHeader: View {
    let title: String
    let subtitle: String
    let step: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            HStack(spacing: AppTheme.Spacing.xs) {
                ForEach(0..<total, id: \.self) { index in
                    Capsule()
                        .fill(
                            index <= step
                                ? AppTheme.Palette.textPrimary
                                : AppTheme.Palette.fillStrong
                        )
                        .frame(width: index == step ? AppTheme.Spacing.xl : AppTheme.Spacing.s,
                               height: AppTheme.Spacing.xs)
                }
            }
            .animation(AppTheme.Motion.standard, value: step)
            .padding(.bottom, AppTheme.Spacing.xs)

            Text(title)
                .font(AppTheme.Typography.sectionTitle)
                .foregroundStyle(AppTheme.Palette.textPrimary)
            Text(subtitle)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The one button that moves the flow forward, in the one place every sheet
/// in the app puts its primary action — pinned to the bottom of the sheet
/// rather than the bottom of however much content there happens to be.
struct ShareStepFooter: View {
    let title: String
    var isEnabled = true
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Spacer()
                if isBusy {
                    ProgressView().tint(AppTheme.Palette.textOnAccent)
                } else {
                    Text(title)
                        .font(AppTheme.Typography.labelEmphasis)
                        .foregroundStyle(AppTheme.Palette.textOnAccent)
                }
                Spacer()
            }
            .padding(.vertical, AppTheme.Spacing.m)
            .background(
                isEnabled ? AppTheme.Palette.textPrimary : AppTheme.Palette.fillStrong,
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.control)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isBusy)
        .padding(.horizontal, AppTheme.Spacing.l)
        .padding(.bottom, AppTheme.Spacing.m)
    }
}

/// A section of selectable rows on one card, or a line saying there is
/// nothing to choose from — never an empty card, which reads as a list that
/// failed to load rather than one with nothing in it.
struct ShareSelectionCard<Item, ID: Hashable, Row: View>: View {
    let items: [Item]
    /// An explicit key path rather than an `Identifiable` bound: the
    /// generated `PublicSchema` types are plain `Codable` structs, and every
    /// other list in the app iterates them the same way.
    let id: KeyPath<Item, ID>
    let emptyMessage: String
    @ViewBuilder var row: (Item) -> Row

    var body: some View {
        if items.isEmpty {
            Text(emptyMessage)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            FormCard(padding: AppTheme.Spacing.s) {
                VStack(spacing: 0) {
                    // `ForEach(_:id:)` over the elements, not over
                    // `enumerated()`: GRDB's own `Array(_: some Cursor)`
                    // overload wins against `Array(EnumeratedSequence)` in
                    // this module and the call stops compiling. Identity comes
                    // from the key path either way, never from an index.
                    ForEach(items, id: id) { item in
                        row(item)
                            .padding(.horizontal, AppTheme.Spacing.s)
                            .padding(.vertical, AppTheme.Spacing.s)
                        if item[keyPath: id] != items.last?[keyPath: id] {
                            Divider().padding(.leading, AppTheme.Size.dividerInset(
                                icon: AppTheme.Size.icon, leading: AppTheme.Spacing.s
                            ))
                        }
                    }
                }
            }
        }
    }
}
