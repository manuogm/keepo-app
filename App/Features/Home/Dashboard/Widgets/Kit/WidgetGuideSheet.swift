import KeepoCore
import SwiftUI

/// The explainer behind an expanded widget's ⓘ.
///
/// **The key does the explaining.** The first version was three paragraphs
/// and it was too much to read mid-task — a help sheet that has to be
/// studied has already failed. So the marks the user is looking at are drawn
/// again, at a glanceable size, with two or three words each; the prose is a
/// single summary line and one line per warning.
///
/// Drawing the marks here rather than describing them is what keeps the
/// sheet honest: the swatches are built from the same `CashflowPalette` and
/// `WidgetPalette` the chart is, so the key cannot end up explaining the
/// widget in a colour the widget stopped using.
///
/// A medium sheet rather than a popover: it is dismissible without aiming at
/// anything, and it resizes to `.large` for a reader on a big Dynamic Type
/// setting.
struct WidgetGuideSheet: View {
    let title: String
    let guide: WidgetGuide

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(guide.summary)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !guide.keys.isEmpty { keyCard }
                    if !guide.notes.isEmpty { notes }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// The key, on its own card. Grouping it makes it read as a legend
    /// belonging to the picture above rather than as three more bullet
    /// points among the warnings below.
    private var keyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(guide.keys.enumerated()), id: \.offset) { _, key in
                HStack(spacing: 12) {
                    GuideMarkView(mark: key.mark)
                        // One column width for every mark, so the labels line
                        // up however wide the swatches are.
                        .frame(width: 32, height: 24)
                    Text(key.meaning)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(guide.notes.enumerated()), id: \.offset) { _, note in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: note.symbol)
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                        .frame(width: 24, alignment: .center)
                    Text(note.text)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One swatch in a guide's key — the chart's own mark, drawn small.
private struct GuideMarkView: View {
    let mark: WidgetGuideMark

    var body: some View {
        switch mark {
        case .incomeBar:
            bar(CashflowPalette.income)
        case .expenseBar:
            bar(CashflowPalette.expense)
        case .valueBar:
            bar(WidgetPalette.neutral)
        case .scaleBar:
            // The backdrop is drawn at the same faintness the chart uses for
            // it, so "bar height is net worth" is shown in the tone the user
            // has to look for.
            bar(WidgetPalette.neutral.opacity(0.2))
        case .netLine, .trendLine:
            line(mark == .netLine ? WidgetPalette.neutral : .green)
        case .dayRing:
            ring(CashflowPalette.expense, fraction: 0.45)
        case .tap:
            Image(systemName: "hand.tap")
                .font(.system(size: 16))
                .foregroundStyle(Color.secondary)
        }
    }

    private func bar(_ color: Color) -> some View {
        Capsule().fill(color).frame(width: 8, height: 24)
    }

    /// A short line with its point on it — a sparkline reduced to the two
    /// things that carry meaning.
    private func line(_ color: Color) -> some View {
        ZStack {
            Capsule().fill(color).frame(width: 24, height: 3)
            Circle().fill(color).frame(width: 8, height: 8)
        }
    }

    /// A ring filled to `fraction` of its circumference, drawn the way the
    /// donut and the day rings both draw theirs.
    private func ring(_ color: Color, fraction: Double) -> some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 4)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 20, height: 20)
    }
}
