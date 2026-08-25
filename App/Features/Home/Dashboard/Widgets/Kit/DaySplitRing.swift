import SwiftUI

/// One day of a calendar carousel: the date, ringed by what is happening on
/// it.
///
/// The ring is **split by type**, not by amount. A day with a €2,000 salary
/// and a €12 subscription has one of each, and sizing the arcs by value would
/// draw the subscription as a hairline — which answers "how much" when the
/// question the row is asking is "what kind of day is this". The amounts are
/// in the list underneath, where they can be read properly.
///
/// Takes `FillSegment`, the same type `WidgetFillBar` does, so a colour means
/// the same thing whether it is drawn as a bar or as an arc.
struct DaySplitRing: View {
    let day: Date
    let segments: [FillSegment]
    let isSelected: Bool
    let isToday: Bool
    var diameter: CGFloat = 38
    /// The calendar the day was decoded in — UTC everywhere in this app, so
    /// a date-only value renders as the day it actually is rather than
    /// shifting for anyone west of it.
    var calendar: Calendar = .current

    /// A slice of the gap between each arc, so two arcs read as two rather
    /// than as one two-coloured ring. As a fraction of the circle, because
    /// the ring is drawn with `trim`.
    private let gap = 0.02

    var body: some View {
        ZStack {
            if isSelected {
                Circle().fill(Color.secondary.opacity(0.18))
            }
            if segments.isEmpty {
                Circle()
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 2.5)
            } else {
                ForEach(Array(arcs.enumerated()), id: \.offset) { _, arc in
                    Circle()
                        .trim(from: arc.start, to: arc.end)
                        .stroke(arc.color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            VStack(spacing: -1) {
                Text(dayNumber)
                    .font(.system(size: diameter * 0.37, weight: isToday ? .bold : .regular))
                    .foregroundStyle(Color.primary)
                    .monospacedDigit()
                Text(weekdayInitial)
                    .font(.system(size: diameter * 0.24))
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
    }

    private struct Arc {
        let start: Double
        let end: Double
        let color: Color
    }

    /// Equal arcs per segment, gapped. `share` is deliberately ignored — see
    /// the type's own header for why this ring counts rather than measures.
    private var arcs: [Arc] {
        let step = 1.0 / Double(segments.count)
        return segments.enumerated().map { index, segment in
            let start = Double(index) * step
            return Arc(
                start: start + (segments.count > 1 ? gap : 0),
                end: start + step - (segments.count > 1 ? gap : 0),
                color: segment.color
            )
        }
    }

    private var dayNumber: String { "\(calendar.component(.day, from: day))" }

    /// One letter, because at this size that is all that fits — and it is
    /// enough to find "the Friday" in a row of fourteen.
    private var weekdayInitial: String {
        let index = calendar.component(.weekday, from: day) - 1
        let symbols = calendar.veryShortWeekdaySymbols
        guard symbols.indices.contains(index) else { return "" }
        return symbols[index]
    }
}
