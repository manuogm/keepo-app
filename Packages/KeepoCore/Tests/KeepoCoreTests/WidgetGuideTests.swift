import Foundation
import Testing

@testable import KeepoCore

/// The ⓘ content behind every widget.
///
/// These are prose tests, which is unusual and deliberate. The guide is the
/// only place the app explains its own arithmetic to the user — that a ratio
/// can pass 100%, that a gap is "not known" rather than zero, that the
/// current period is deliberately not the one shown — and a widget added
/// later with an empty or half-written guide would ship a silent hole in
/// that explanation. Nothing else in the build would notice.
@Suite("Widget guides")
struct WidgetGuideTests {
    @Test("Every widget explains itself, briefly")
    func everyKindHasAGuide() {
        for kind in DashboardWidgetKind.allCases {
            let guide = kind.guide
            #expect(!guide.summary.isEmpty, "\(kind) has no summary")
            #expect(!guide.keys.isEmpty, "\(kind) draws marks it never explains")
            // Brevity is the requirement this sheet was rewritten for, so it
            // is the thing worth pinning: the first version was three
            // paragraphs and was too much to read mid-task. A budget catches
            // the drift back long before a person notices it.
            #expect(guide.summary.count <= 70, "\(kind)'s summary has grown back into a paragraph")
            for key in guide.keys {
                #expect(key.meaning.count <= 46, "\(kind): key '\(key.meaning)' is a sentence, not a label")
            }
            for note in guide.notes {
                #expect(note.text.count <= 72, "\(kind): note '\(note.text)' is too long for one line")
                #expect(!note.symbol.isEmpty, "\(kind) has a note with no glyph")
            }
        }
    }

    /// The notes are the half that earns the button. Two widgets genuinely
    /// have little that surprises — but the four whose arithmetic can be
    /// misread must each say so, and this pins which four.
    @Test("The widgets that can be misread say how")
    func surprisingKindsCarryNotes() {
        let mustExplain: [DashboardWidgetKind] = [.netWorth, .investingRatio, .cashflow, .fxRate]
        for kind in mustExplain {
            #expect(kind.guide.notes.count >= 2, "\(kind) hides more than one surprise and admits to fewer")
        }
    }

    @Test("Negative balances are explained where they change the answer")
    func negativesAreExplained() {
        // Net worth and the investing ratio are the two figures a debt moves
        // in a direction the user won't predict: it lowers net worth, which
        // *raises* the ratio. Both say so, in their own words.
        let netWorth = DashboardWidgetKind.netWorth.guide.notes.map(\.text).joined(separator: " ").lowercased()
        #expect(netWorth.contains("overdrawn") || netWorth.contains("debt"))

        let ratio = DashboardWidgetKind.investingRatio.guide.notes.map(\.text).joined(separator: " ").lowercased()
        #expect(ratio.contains("debt"))
    }

    /// Money rule 5, in the one place the user reads about it. A figure that
    /// can't be computed is a gap, and each guide has to rule out the wrong
    /// reading of that gap — a different wrong reading per widget, so the
    /// check is per widget rather than a blanket search for "zero".
    @Test("A gap is explained as unknown rather than as nothing", arguments: [
        (DashboardWidgetKind.netWorth, "zero"),
        (DashboardWidgetKind.currencyExposure, "zero"),
        (DashboardWidgetKind.fxRate, "no rate")
    ])
    func gapsAreExplained(kind: DashboardWidgetKind, wrongReading: String) {
        let text = kind.guide.notes.map(\.text).joined(separator: " ").lowercased()
        #expect(text.contains("gap") || text.contains("left out"), "\(kind) doesn't explain its missing data")
        #expect(text.contains(wrongReading), "\(kind) doesn't rule out reading a gap as '\(wrongReading)'")
    }

    /// A key row with no mark to draw would render as a blank column and an
    /// orphaned label. Cheap to assert, and it is the shape of mistake that
    /// comes from adding a widget by copying another's guide.
    @Test("Cashflow's key names both directions and the net")
    func cashflowKeyIsComplete() {
        let marks = DashboardWidgetKind.cashflow.guide.keys.map(\.mark)
        #expect(marks.contains(.incomeBar))
        #expect(marks.contains(.expenseBar))
        #expect(marks.contains(.netLine))
    }
}
