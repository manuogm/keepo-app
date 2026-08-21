import KeepoCore
import SwiftUI

/// Everything the dashboard says through the Taptic Engine, in one place.
///
/// Gathered into a modifier rather than sprinkled through the canvas because
/// haptics are a *vocabulary*: four separate `.sensoryFeedback` modifiers
/// spread across a view body are four independent decisions that drift into
/// buzzing over each other. Here the whole set is readable at once, and it
/// is short on purpose — a dashboard that vibrates at everything says
/// nothing.
///
/// Feedback is picked in a closure rather than fired on every change, so
/// each of these speaks in one direction only: picking a widget up is worth
/// a bump, putting the state back down is not.
///
/// The lift is the load-bearing one. A drag out of the catalogue is a system
/// drag session, and UIKit stretches its press-and-hold when the source sits
/// inside a scroll view so that scrolling can still win — which leaves a
/// noticeable, silent wait where the user cannot tell whether the press has
/// registered. The duration is not ours to shorten; the acknowledgement is.
struct DashboardHaptics: ViewModifier {
    let isEditing: Bool
    /// The widget currently being carried in from the catalogue.
    let carriedId: UUID?
    /// The tile currently lifted off the grid.
    let draggedId: UUID?
    /// The cell a live drag would drop into.
    let targetCell: DashboardGridCell?
    /// Whether letting go would throw the carried widget away.
    let isOverTrash: Bool
    let arrangement: DashboardArrangement

    // Each stage is its own function with a written-out return type. As one
    // chained expression the type checker gives up on it — five generic
    // `sensoryFeedback` overloads with inferred closures is past what it
    // will solve.
    func body(content: Content) -> some View {
        landing(trash(cellChanges(tilePickUp(widgetLift(editMode(content))))))
    }

    /// Entering edit mode, never leaving it — the same asymmetry the home
    /// screen has, where the jiggle starting is an event and the jiggle
    /// stopping is just a return to normal.
    private func editMode(_ content: Content) -> some View {
        content.sensoryFeedback(trigger: isEditing) { (was: Bool, now: Bool) -> SensoryFeedback? in
            now && !was ? .impact(weight: .medium) : nil
        }
    }

    /// A widget has left the catalogue and is in hand.
    private func widgetLift(_ content: some View) -> some View {
        content.sensoryFeedback(trigger: carriedId) { (_: UUID?, now: UUID?) -> SensoryFeedback? in
            now != nil ? .impact(weight: .medium) : nil
        }
    }

    /// A tile already on the grid has been picked up. Lighter than a lift out
    /// of the catalogue: less of a commitment, and it happens far more often.
    private func tilePickUp(_ content: some View) -> some View {
        content.sensoryFeedback(trigger: draggedId) { (was: UUID?, now: UUID?) -> SensoryFeedback? in
            was == nil && now != nil ? .impact(weight: .light) : nil
        }
    }

    /// The landing cell moved. The tick is what makes a drag feel like it is
    /// snapping to something rather than floating.
    private func cellChanges(_ content: some View) -> some View {
        content.sensoryFeedback(trigger: targetCell, Self.tick)
    }

    private static func tick(_ was: DashboardGridCell?, _ now: DashboardGridCell?) -> SensoryFeedback? {
        now != nil ? .selection : nil
    }

    /// Crossing into the trash. Rigid, where the rest of this vocabulary is
    /// soft: it is the one boundary on the dashboard behind which a drag ends
    /// with nothing happening, and it should feel like hitting something
    /// rather than like settling onto a cell. The cell tick falls silent at
    /// the same moment — the preview freezes over the trash — so the two
    /// never overlap.
    private func trash(_ content: some View) -> some View {
        content.sensoryFeedback(trigger: isOverTrash) { (was: Bool, now: Bool) -> SensoryFeedback? in
            now && !was ? .impact(flexibility: .rigid, intensity: 0.8) : nil
        }
    }

    /// Something actually landed — or was removed. The one piece of feedback
    /// tied to a committed change rather than to a gesture.
    private func landing(_ content: some View) -> some View {
        content.sensoryFeedback(.impact(weight: .light), trigger: arrangement)
    }
}
