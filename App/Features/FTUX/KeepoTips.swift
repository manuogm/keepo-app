import KeepoCore
import SwiftUI
import TipKit

/// One `Tip` per `FTUXLesson`, so the just-in-time popover and the
/// "Show me around" screen render the same sentence from the same place.
///
/// **One rule, and it is the rule §3.11 is about: nothing until the
/// spotlight is done.** Without it the two collide on a first launch —
/// observed, not theorised: the Home widgets tip popped up *inside* the
/// spotlight's cut-out, so the coach mark dimming the whole screen appeared
/// to be pointing at a second coach mark. Two interruptions at once is
/// precisely what teaching things just-in-time was meant to avoid.
///
/// Beyond that there are no rules. A tip is attached to exactly one view,
/// on exactly the screen its lesson is about, so "is this relevant?" is
/// answered by *where it is* rather than by a predicate that has to be kept
/// in step with the UI. TipKit's own once-per-user persistence handles the
/// rest — which is the whole reason the tips are its and only the spotlight
/// is ours.
struct LessonTip: Tip {
    /// Set by `FTUXCoordinator` when the spotlight is dismissed, and synced
    /// from the persisted flag at launch so a returning user is not gated
    /// on a coach mark they already closed.
    @Parameter static var isSpotlightDone: Bool = false

    let lesson: FTUXLesson

    var id: String { lesson.id }
    var title: Text { Text(lesson.title) }
    var message: Text? { Text(lesson.message) }
    var image: Image? { Image(systemName: lesson.symbol) }

    var rules: [Rule] {
        #Rule(Self.$isSpotlightDone) { $0 == true }
    }
}

/// The tips, named so a call site reads as the thing it is teaching.
///
/// **`scope` is deliberately absent**: that lesson is the spotlight's, and
/// a popover saying the same thing would be the second time Keepo taught
/// one gesture.
enum KeepoTips {
    static let accounts = LessonTip(lesson: FTUXLessons.accounts)
    static let categories = LessonTip(lesson: FTUXLessons.categories)
    static let widgets = LessonTip(lesson: FTUXLessons.widgets)
    static let needsReview = LessonTip(lesson: FTUXLessons.needsReview)
    static let privacy = LessonTip(lesson: FTUXLessons.privacy)
    static let add = LessonTip(lesson: FTUXLessons.add)
}
