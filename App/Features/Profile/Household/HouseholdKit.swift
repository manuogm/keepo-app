import KeepoCore
import SwiftUI

// The pieces every household screen is built from. They live together because
// the setup flow, the report and the live Household screen are one continuous
// experience to the user — the container they see while choosing what to share
// is the same container they see six months later — and three copies of it
// would have drifted by the second screen.

/// The household, as a picture: the two of you with the house between.
///
/// Repeated at the top of every report screen and again on the Household
/// screen itself, static and unchanging, because it is the answer to "what am
/// I looking at" and that answer must not move while the content under it
/// does. The dotted connectors are the whole idea — two people, joined.
struct HouseholdContainer: View {
    let owner: HouseholdMemberView
    let guest: HouseholdMemberView
    /// "Since Sep 26". Hidden until the household actually exists — during
    /// setup there is no date to state, and a badge reading the day it is
    /// about to be created would be the screen getting ahead of itself.
    var since: String?
    /// Tapping the other member opens their profile, or the option to remove
    /// them. Nil while the household is still being built: there is nobody to
    /// remove from something that does not exist yet.
    var onTapOther: (() -> Void)?

    var body: some View {
        // Top-aligned and hugging its own content rather than spread across
        // the screen: the three things are one object — two people and the
        // house they share — and a row that distributes them edge to edge
        // reads as three separate columns that happen to be on the same line.
        HStack(alignment: .top, spacing: AppTheme.Spacing.xs) {
            member(owner)
            connector
            house
            connector
            member(guest)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func member(_ member: HouseholdMemberView) -> some View {
        let content = VStack(spacing: AppTheme.Spacing.s) {
            ProfileAvatarView(
                name: member.name, email: nil, image: member.image, size: AppTheme.Size.avatar
            )
            Text(member.name)
                .font(AppTheme.Typography.captionEmphasis)
                .foregroundStyle(AppTheme.Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                // Capped rather than flexible, so a long name cannot push the
                // house away from the people it belongs to.
                .frame(maxWidth: AppTheme.Size.illustration)
        }

        if !member.isMe, let onTapOther {
            Button(action: onTapOther) { content }
                .buttonStyle(.pressableCard)
                .accessibilityLabel("\(member.name), household member")
                .accessibilityHint("Opens their profile, or removes them from the household")
        } else {
            content
        }
    }

    private var house: some View {
        VStack(spacing: AppTheme.Spacing.s) {
            // The same diameter as the two faces beside it. The house is the
            // third member of this row, not an ornament between two members.
            KeepoIcon(name: "icon-home-filled", size: AppTheme.Size.avatar)
                .foregroundStyle(PublicSchema.AccountScope.household.tint)

            if let since {
                Text(since)
                    .font(AppTheme.Typography.nano)
                    .foregroundStyle(AppTheme.Palette.textOnAccent)
                    .lineLimit(1)
                    // Never truncated: "Since S…" is not a date. The badge
                    // takes whatever width its own text needs and the row
                    // makes room, rather than the badge being squeezed to fit
                    // a column it was never measured against.
                    .fixedSize()
                    .padding(.horizontal, AppTheme.Spacing.s)
                    .padding(.vertical, AppTheme.Spacing.xxs)
                    .background(
                        Capsule().fill(PublicSchema.AccountScope.household.tint)
                    )
            } else {
                // The badge's own height, held empty, so the house sits at
                // the same level whether or not there is a date to state.
                Color.clear.frame(height: AppTheme.Spacing.l)
            }
        }
    }

    /// Drawn rather than a `Divider`: a dotted line is the one shape that
    /// says "linked, but still two things", and it is the same stroke style
    /// the merge sheet uses between two categories for the same reason.
    ///
    /// A fixed short length, not a flexible one. Stretched to fill, it read
    /// as two long leads with a house marooned in the middle; at this length
    /// the three parts group.
    private var connector: some View {
        Line()
            .stroke(
                PublicSchema.AccountScope.household.tint.opacity(AppTheme.Opacity.fillStrong),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 4])
            )
            .frame(width: AppTheme.Spacing.xl, height: 1)
            // Level with the middle of the avatars, which the top alignment
            // makes a fixed offset rather than something the labels can move.
            .padding(.top, AppTheme.Size.avatar / 2)
    }
}

/// One member, reduced to what the container draws.
struct HouseholdMemberView: Equatable {
    let name: String
    let image: UIImage?
    let isMe: Bool
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

// MARK: - Cards

/// A titled card, which is what every block in the report is.
///
/// Wraps `FormCard` rather than replacing it: the surface, radius and inset
/// are the app's, and this only adds the small caps label the report needs
/// above each one.
struct HouseholdCard<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            Text(title.uppercased())
                .font(AppTheme.Typography.nanoEmphasis)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .kerning(0.6)
            FormCard {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
                    if let subtitle {
                        Text(subtitle)
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    content
                }
            }
        }
    }
}

/// One of the paired figures the report leads its cards with — "Everyday 3 /
/// Investment 1". A count, not money, so it is drawn here rather than through
/// `MetricHeadline`, which is about currency and privacy mode.
struct HouseholdMetric: View {
    let value: Int
    let label: String
    var tint: Color = AppTheme.Palette.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text("\(value)")
                .numberFont(AppTheme.Typography.Number.metricCompact)
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(label)
                .font(AppTheme.Typography.micro)
                .foregroundStyle(AppTheme.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Rows

/// An account anywhere in the household screens — the pickers, the report's
/// lists, the summary. Icon and colour, name, the investment badge, and
/// whatever the caller needs on the trailing edge.
///
/// One row rather than four, because the spec asks for the same thing in four
/// places and the only difference is what sits at the end: a toggle while you
/// are choosing, a balance while you are reviewing, a sharing glyph for
/// somebody else's.
struct HouseholdAccountRow<Trailing: View>: View {
    let name: String
    let icon: String
    let color: Color
    let isInvestment: Bool
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: AppTheme.Spacing.m) {
            CategoryIconView(icon: icon, color: color)

            HStack(spacing: AppTheme.Spacing.xs) {
                Text(name)
                    .font(AppTheme.Typography.label)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                    .lineLimit(1)
                if isInvestment {
                    InvestmentBadge(compact: true)
                }
            }

            Spacer(minLength: AppTheme.Spacing.s)
            trailing
        }
        .padding(.vertical, AppTheme.Spacing.xs)
    }
}

/// The same, for a category: icon, colour, name, and whatever the screen puts
/// at the end.
struct HouseholdCategoryRow<Trailing: View>: View {
    let name: String
    let icon: String
    let color: Color
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: AppTheme.Spacing.m) {
            CategoryIconView(icon: icon, color: color)
            Text(name)
                .font(AppTheme.Typography.label)
                .foregroundStyle(AppTheme.Palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: AppTheme.Spacing.s)
            trailing
        }
        .padding(.vertical, AppTheme.Spacing.xs)
    }
}

/// The marker on a row that belongs to the other member — the read-only
/// counterpart of the toggle on your own rows.
///
/// A glyph rather than a disabled toggle: a switch you cannot flip invites
/// the user to try, and then says nothing about why it did not move. This
/// says whose it is.
struct SharedByThemIcon: View {
    var body: some View {
        KeepoIcon(name: "icon-shared", size: AppTheme.Size.glyphSmall)
            .foregroundStyle(AppTheme.Palette.textSecondary)
            .accessibilityLabel("Shared with you")
    }
}

/// A section that folds away, used for every list in the report.
///
/// The count in the header is not decoration: these lists collapse, and a
/// closed section with no count is a section the user has to open to find out
/// whether it was worth opening.
///
/// `hasRows` is for a list that holds more than it counts: the summary counts
/// what is shared and also lists what could be, and gating "Nothing here." on
/// the count drew it over the very rows the user came to switch on.
struct HouseholdDisclosure<Content: View>: View {
    let title: String
    let count: Int
    var hasRows: Bool?
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content

    private var isEmpty: Bool { hasRows.map { !$0 } ?? (count < 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(AppTheme.Motion.standard) { isExpanded.toggle() }
            } label: {
                HStack(spacing: AppTheme.Spacing.s) {
                    Text(title)
                        .font(AppTheme.Typography.labelEmphasis)
                        .foregroundStyle(AppTheme.Palette.textPrimary)
                    Text("\(count)")
                        .font(AppTheme.Typography.nanoEmphasis)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                        .padding(.horizontal, AppTheme.Spacing.s)
                        .padding(.vertical, AppTheme.Spacing.xxs)
                        .background(Capsule().fill(AppTheme.Palette.fillSubtle))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(AppTheme.Typography.microEmphasis)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .contentShape(Rectangle())
                .padding(.vertical, AppTheme.Spacing.s)
            }
            .buttonStyle(.plain)
            .sensoryFeedback(AppTheme.Feedback.toggle, trigger: isExpanded)

            if isExpanded {
                if isEmpty {
                    Text("Nothing here.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                        .padding(.bottom, AppTheme.Spacing.s)
                } else {
                    content
                }
            }
        }
    }
}

// MARK: - Navigation

/// The step's controls: Back on the left where there is somewhere to go back
/// to, the one primary action on the right.
///
/// Right-aligned rather than full-width, which is the spec's own call and the
/// right one here: these screens are a sequence being stepped through, not a
/// form being submitted, and a full-width button at the bottom of each one
/// would read as nine separate commitments.
///
/// **It scrolls with the page.** Pinned to the bottom it covered the last row
/// of every list it sat over — and on the report, a floating bar over a card
/// read as chrome belonging to the app rather than to the step. Living at the
/// end of the content also means reaching it *is* reaching the end, which is
/// the right gate for a screen whose whole job is to be read.
struct HouseholdFlowBar: View {
    var backTitle: String?
    var onBack: (() -> Void)?
    let nextTitle: String
    var isEnabled = true
    var isBusy = false
    let onNext: () -> Void

    var body: some View {
        HStack {
            if let onBack {
                Button(action: onBack) {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Image(systemName: "chevron.left")
                        Text(backTitle ?? "Back")
                    }
                    .font(AppTheme.Typography.labelEmphasis)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Button(action: onNext) {
                HStack(spacing: AppTheme.Spacing.s) {
                    if isBusy {
                        ProgressView().tint(AppTheme.Palette.textOnAccent)
                    } else {
                        Text(nextTitle)
                    }
                }
                .font(AppTheme.Typography.labelEmphasis)
                .foregroundStyle(AppTheme.Palette.textOnAccent)
                .padding(.horizontal, AppTheme.Spacing.xl)
                .padding(.vertical, AppTheme.Spacing.m)
                .background(
                    isEnabled
                        ? PublicSchema.AccountScope.household.tint
                        : AppTheme.Palette.fillStrong,
                    in: Capsule()
                )
            }
            .buttonStyle(.pressableCard)
            .disabled(!isEnabled || isBusy)
            .sensoryFeedback(AppTheme.Feedback.buttonPress, trigger: isBusy)
        }
        .padding(.top, AppTheme.Spacing.s)
    }
}
