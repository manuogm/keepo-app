import Foundation

/// One row of a widget's visual key: a mark to draw, and the two or three
/// words it means.
public struct WidgetGuideKey: Sendable, Equatable {
    public let mark: WidgetGuideMark
    public let meaning: String

    public init(_ mark: WidgetGuideMark, _ meaning: String) {
        self.mark = mark
        self.meaning = meaning
    }
}

/// What to draw beside a key's label.
///
/// A *role*, not a colour. `KeepoCore` has no SwiftUI in it, and more to the
/// point the dashboard's colours are decided in exactly one place
/// (`WidgetPalette`, `CashflowPalette`) — a guide that carried its own hex
/// values would be free to explain the chart in colours the chart had
/// stopped using.
public enum WidgetGuideMark: String, Sendable, Equatable {
    case incomeBar
    case expenseBar
    case netLine
    case trendLine
    case valueBar
    case scaleBar
    case dayRing
    case tap
}

/// A short warning: one glyph, one line.
public struct WidgetGuideNote: Sendable, Equatable {
    /// SF Symbol name. A string is data, so it belongs here with the text it
    /// labels rather than in a lookup table the view has to keep in step.
    public let symbol: String
    public let text: String

    public init(_ symbol: String, _ text: String) {
        self.symbol = symbol
        self.text = text
    }
}

/// What a widget is telling you — the content behind the ⓘ in an expanded
/// widget's header.
///
/// **Deliberately short.** The first version of this was three paragraphs of
/// prose and it failed the only test that matters for a help sheet: nobody
/// reads a wall of text they opened mid-task. So the explanation is carried
/// by the *key* — the marks the user is already looking at, drawn again with
/// two words beside them — and the prose is cut back to one line of summary
/// and one line per warning.
///
/// The notes are still the half that earns the button. They are the things
/// that would otherwise be read wrong: a ratio that can pass 100%, a gap
/// that means "not known", a period that is still open.
public struct WidgetGuide: Sendable, Equatable {
    /// One line. What the widget is, not how it works.
    public let summary: String
    /// The marks on screen, explained by being drawn again.
    public let keys: [WidgetGuideKey]
    /// What would otherwise be misread. Most surprising first.
    public let notes: [WidgetGuideNote]

    public init(summary: String, keys: [WidgetGuideKey], notes: [WidgetGuideNote]) {
        self.summary = summary
        self.keys = keys
        self.notes = notes
    }
}

public extension DashboardWidgetKind {
    /// The explainer behind this widget's ⓘ.
    ///
    /// Written against the **rules the code actually follows**, not against
    /// the design intent — money rule 5's gaps, the signed-amount model, the
    /// investment flag being a declaration rather than a guess. If one of
    /// those rules changes, this text is part of what changes with it.
    var guide: WidgetGuide {
        switch self {
        case .netWorth:
            return WidgetGuide(
                summary: "Everything you own, minus everything you owe.",
                keys: [
                    WidgetGuideKey(.trendLine, "Your net worth, period by period"),
                    WidgetGuideKey(.tap, "Tap a point to read that period")
                ],
                notes: [
                    WidgetGuideNote("creditcard", "Debts subtract — an overdrawn card pulls the total down."),
                    WidgetGuideNote("questionmark.circle", "A gap means the rate wasn't known. It never means zero."),
                    WidgetGuideNote("chart.line.uptrend.xyaxis", "Investments are counted like any other account.")
                ]
            )
        case .investingRatio:
            return WidgetGuide(
                summary: "How much of your net worth is invested.",
                keys: [
                    WidgetGuideKey(.scaleBar, "Bar height is that period's net worth"),
                    WidgetGuideKey(.valueBar, "The filled part is what's invested"),
                    WidgetGuideKey(.tap, "Tap a bar to read that period")
                ],
                notes: [
                    WidgetGuideNote("percent", "Moves in points: 30% to 33% is +3 pts, not +10%."),
                    WidgetGuideNote("arrow.up.forward", "Can pass 100% if you hold investments against debt."),
                    WidgetGuideNote("creditcard", "Paying off debt raises this without you buying anything.")
                ]
            )
        case .currencyExposure:
            return WidgetGuide(
                summary: "Which currencies your money sits in.",
                keys: [
                    WidgetGuideKey(.valueBar, "The darkest band is your biggest"),
                    WidgetGuideKey(.scaleBar, "Lighter bands hold less"),
                    WidgetGuideKey(.tap, "Open a currency for its accounts")
                ],
                notes: [
                    WidgetGuideNote("percent", "Shares are worked out on the converted values, in your base currency."),
                    WidgetGuideNote("questionmark.circle", "No rate means left out, never counted as zero."),
                    WidgetGuideNote("minus.circle", "Debts net inside their own currency's slice.")
                ]
            )
        case .upcomingBills:
            return WidgetGuide(
                summary: "What's due to arrive and leave over the next 14 days.",
                keys: [
                    WidgetGuideKey(.dayRing, "One ring per day"),
                    WidgetGuideKey(.expenseBar, "The coloured arc is money going out"),
                    WidgetGuideKey(.tap, "Tap a day to open the rules behind it")
                ],
                notes: [
                    WidgetGuideNote("calendar.badge.clock", "Predictions from your rules. No balance moves yet."),
                    WidgetGuideNote("questionmark.circle", "A varying amount shows its date without a figure.")
                ]
            )
        case .cashflow:
            return WidgetGuide(
                summary: "What came in against what went out.",
                keys: [
                    WidgetGuideKey(.incomeBar, "Above the line: money in"),
                    WidgetGuideKey(.expenseBar, "Below the line: money out"),
                    WidgetGuideKey(.netLine, "The line across them is the net"),
                    WidgetGuideKey(.tap, "Tap a bar to load its categories")
                ],
                notes: [
                    WidgetGuideNote("clock", "Opens on the last finished period, not this one."),
                    WidgetGuideNote("arrow.left.arrow.right", "Transfers count only when they cross your scope."),
                    WidgetGuideNote("questionmark.circle", "A category with no rate leaves the bar short of the end.")
                ]
            )
        case .fxRate:
            return WidgetGuide(
                summary: "What one unit of a currency you hold is worth in yours.",
                keys: [
                    WidgetGuideKey(.trendLine, "The rate over time"),
                    WidgetGuideKey(.tap, "Tap a point to read that period")
                ],
                notes: [
                    WidgetGuideNote("equal.circle", "The same conversion every balance here uses."),
                    WidgetGuideNote("eurosign.circle", "Pivoted through the euro. A gap means no rate."),
                    WidgetGuideNote("calendar", "Monthly and yearly points are averages.")
                ]
            )
        }
    }
}
