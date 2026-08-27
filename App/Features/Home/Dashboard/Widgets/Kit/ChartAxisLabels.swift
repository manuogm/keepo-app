import KeepoCore
import SwiftUI
import UIKit

/// Choosing how to write a chart's x-axis labels so that **every** bucket
/// gets one.
///
/// The axis used to thin its labels: at twelve visible buckets it labelled
/// every one, at forty every fourth. That is the textbook answer to a
/// crowded scale and it is the wrong one here, because these charts are
/// short — six to twelve bars — and a reader looking at five bars with two
/// labels under them has to count to work out which bar is March. Labels
/// also had to be inset from the plot edge to stop the first one being
/// clipped, which moved them off their own buckets and made the
/// misalignment the user noticed.
///
/// So the label under a bar is always that bar's label, and it is the
/// *writing* that gives way instead: "Jan" where a bucket's slot has room
/// for it, "J" where it hasn't. Chosen once for the whole axis rather than
/// per bucket, because a row reading "Jan F Mar A May" would look broken
/// rather than adaptive.
enum ChartAxisLabels {
    /// The label for every bucket, all written at the widest form that fits.
    ///
    /// Measured against the real font — `UIFont.preferredFont` follows the
    /// user's Dynamic Type setting, so a reader on the largest text size
    /// drops to the short form at a bucket count where the default setting
    /// would still have room for the long one. Guessing a character count
    /// instead would have been right at exactly one text size.
    static func fitted(
        buckets: [Date],
        granularity: MetricGranularity,
        slotWidth: CGFloat,
        calendar: Calendar = utcCalendar
    ) -> [String] {
        guard !buckets.isEmpty else { return [] }
        let ladders = buckets.map { granularity.axisLabelCandidates(for: $0, calendar: calendar) }
        guard let depth = ladders.map(\.count).min(), depth > 0 else { return buckets.map { _ in "" } }

        // The gutter is what keeps two neighbouring labels from touching,
        // which reads as one long word rather than as two labels.
        let available = slotWidth - gutter
        let font = UIFont.preferredFont(forTextStyle: .caption1)
        for tier in 0 ..< depth {
            let widest = ladders.reduce(into: CGFloat.zero) { widest, ladder in
                widest = max(widest, width(of: ladder[tier], font: font))
            }
            if widest <= available { return ladders.map { $0[tier] } }
        }
        // Nothing fits: the shortest form anyway, clipped by the axis rather
        // than left blank. A cramped label is still a label; an empty axis
        // is a chart the reader cannot place in time at all.
        return ladders.map { $0[depth - 1] }
    }

    private static let gutter: CGFloat = 4

    private static func width(of text: String, font: UIFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}
