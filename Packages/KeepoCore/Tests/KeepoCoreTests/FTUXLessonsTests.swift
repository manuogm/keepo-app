import Foundation
import Testing
@testable import KeepoCore

/// The lesson copy is shared by two surfaces that are never on screen
/// together — a just-in-time tip and the "Show me around" page — so the
/// only way a mismatch shows up is a test.
@Suite("FTUX lessons")
struct FTUXLessonsTests {
    /// TipKit keys its once-per-user persistence on `Tip.id`, which is this
    /// value. Two lessons sharing one would mean showing one of them and
    /// permanently suppressing the other.
    @Test("every lesson has its own id")
    func idsAreUnique() {
        let ids = FTUXLessons.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    /// The tour is the complete list — a lesson that exists but is not on
    /// it is one nobody can ever go back and read.
    @Test("the tour lists every lesson that exists")
    func tourIsComplete() {
        let named = [
            FTUXLessons.scope, FTUXLessons.accounts, FTUXLessons.categories,
            FTUXLessons.widgets, FTUXLessons.needsReview, FTUXLessons.privacy, FTUXLessons.add
        ]
        #expect(FTUXLessons.all == named)
    }

    /// The scope swipe is taught by the spotlight, which reads this exact
    /// value — so it has to be on the tour *and* be the one the coach mark
    /// points at.
    @Test("the scope lesson is on the tour and is the spotlight's")
    func scopeIsTheSpotlightLesson() {
        #expect(FTUXLessons.all.contains(FTUXLessons.scope))
        #expect(FTUXLessons.scope.id == "scope")
    }

    /// One sentence each. A tip that needs a paragraph is a feature that
    /// needs redesigning — and a popover that long is a popover nobody
    /// reads.
    @Test("every lesson stays short enough to be a popover")
    func lessonsAreShort() {
        for lesson in FTUXLessons.all {
            #expect(!lesson.title.isEmpty, "\(lesson.id) has no title")
            #expect(lesson.title.count <= 42, "\(lesson.id)'s title is \(lesson.title.count) characters")
            #expect(lesson.message.count <= 110, "\(lesson.id)'s message is \(lesson.message.count) characters")
            #expect(!lesson.symbol.isEmpty, "\(lesson.id) has no symbol")
        }
    }
}
