import KeepoCore
import Observation
import SwiftUI

/// Owns the coach marks — which one is on screen, which have been seen, and
/// the switch that turns them back on.
///
/// **Every lesson Keepo teaches is now a coach mark**, and TipKit is gone
/// with the last popover. Each lesson is about a gesture on one specific
/// control — swipe this, drag that, press here — and a popover that sits
/// *near* a control cannot say *this one*. Keeping a second framework
/// configured, gated and persisted for zero call sites was the thing to
/// delete, not to maintain.
///
/// **Screens offer, the coordinator decides.** A screen knows when its
/// control is on display — there is no account row to point at before one
/// loads, no inbox drawer until something is waiting — so it calls
/// `offer(_:)` and nothing else. Which of the offered lessons goes first is
/// the order of `FTUXLessons.all`, so two coach marks on one screen have a
/// defined sequence no matter which part of the screen asked first.
///
/// **One at a time.** `visible` is a single lesson: a coach mark arriving
/// while one is up would be an interruption interrupting an interruption.
/// The next unseen one in the queue follows on the same settle beat once
/// its predecessor is dismissed, which is what turns three lessons on the
/// Dashboard into a short tour rather than a pile.
@Observable
@MainActor
final class FTUXCoordinator {
    /// The coach mark on screen right now, if any.
    private(set) var visible: FTUXLesson?

    /// Raised while the Profile sheet is up. A coach mark under a modal
    /// points at something the user cannot see, and it would spend its one
    /// showing doing it.
    var isModalPresented = false

    /// What the current screen has on offer, in `FTUXLessons.all` order.
    /// Cleared on every tab change, because an offer is a statement about
    /// what is on screen and nothing in it survives leaving.
    private var queue: [FTUXLesson] = []

    /// Long enough for the screen to have drawn and any phase transition to
    /// have settled, short enough that it still reads as part of arriving
    /// rather than as something that appeared later.
    private static let settle = Duration.milliseconds(600)

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// One key per lesson, derived rather than listed, so a new coach mark
    /// is a new lesson and nothing else.
    static func seenKey(_ lesson: FTUXLesson) -> String {
        AppSettingsKeys.spotlightSeenPrefix + lesson.id
    }

    func hasSeen(_ lesson: FTUXLesson) -> Bool {
        defaults.bool(forKey: Self.seenKey(lesson))
    }

    func isVisible(_ lesson: FTUXLesson) -> Bool {
        visible?.id == lesson.id
    }

    // MARK: - Offering

    /// Adds `lessons` to what this screen is teaching and shows the first
    /// unseen one.
    ///
    /// Additive rather than replacing, because a screen is not always one
    /// view: the Transactions ledger offers the swipe lesson and the inbox
    /// drawer offers its own, each when it has something to point at. The
    /// sort is what keeps them in a fixed order regardless of which arrived
    /// first.
    func offer(_ lessons: [FTUXLesson]) async {
        let ids = Set(queue.map(\.id)).union(lessons.map(\.id))
        queue = FTUXLessons.all.filter { ids.contains($0.id) }
        await showNext()
    }

    /// Everything on offer is off screen now. Called on a tab change, which
    /// is the one moment every screen's controls are replaced at once.
    func clearQueue() {
        queue = []
    }

    /// Try again with what is already on offer — after the Profile sheet
    /// closes, say, which is a coach mark's cue that the screen is its own
    /// again.
    func retry() async {
        await showNext()
    }

    /// **Which lesson is chosen *after* the settle beat, never before.**
    /// A screen's offer can grow during those 600ms — Accounts offers Add
    /// straight away and the drag lesson once its rows load — and a choice
    /// made up front committed to whichever was on offer first, putting Add
    /// ahead of a lesson that should precede it. Measured on the simulator;
    /// the queue is re-read on the far side of the sleep so the order is
    /// always `FTUXLessons.all`'s.
    private func showNext() async {
        guard canShowSomething, queue.contains(where: { !hasSeen($0) }) else { return }
        try? await Task.sleep(for: Self.settle)
        // Re-checked, not assumed: 600ms is long enough for the user to have
        // opened Profile, changed tab, or dismissed the thing themselves.
        guard !Task.isCancelled, canShowSomething,
            let next = queue.first(where: { !hasSeen($0) })
        else { return }
        visible = next
    }

    private var canShowSomething: Bool {
        visible == nil && !isModalPresented
    }

    // MARK: - Dismissing

    /// Marks the coach mark on screen as seen, takes it down, and lets the
    /// next one on this screen follow.
    func dismiss() {
        guard let lesson = visible else { return }
        defaults.set(true, forKey: Self.seenKey(lesson))
        visible = nil
        Task { await showNext() }
    }

    /// The same, but only if `lesson` is the one on screen.
    ///
    /// For a host reporting that the user just *did the thing* — dragged
    /// the row, pressed the button, entered edit mode. Learning by doing
    /// ends the lesson, and a coach mark that outlived the gesture it was
    /// teaching would be dimming the screen over the result.
    func dismiss(_ lesson: FTUXLesson) {
        guard isVisible(lesson) else { return }
        dismiss()
    }

    /// Takes down a coach mark that has nothing to point at, **without
    /// marking it seen**, and drops it from this screen's offer.
    ///
    /// The lesson was offered in good faith and the control then went away
    /// — the inbox drawer closing as its last item syncs is the real case.
    /// Dropping it is what stops the next attempt picking the same one
    /// again a beat later; it is still unseen, so the next screen that can
    /// actually show it will.
    func suspend() {
        guard let lesson = visible else { return }
        visible = nil
        queue.removeAll { $0.id == lesson.id }
        Task { await showNext() }
    }

    /// The replay, from Profile → Show Me Around. Arms **every** coach
    /// mark again.
    ///
    /// Nothing is shown from here, and that is deliberate: a coach mark
    /// belongs to a screen, and the one underneath this sheet is only one
    /// of three. Each screen offers its own as it is reached — which is
    /// also the order a first run has them in. What makes the first one
    /// appear is the sheet closing, which is `retry()`.
    func replayAll() {
        for lesson in FTUXLessons.all {
            defaults.set(false, forKey: Self.seenKey(lesson))
        }
    }
}

#if DEBUG
extension FTUXCoordinator {
    /// **Every coach mark again**, for reading the first-time copy twice.
    ///
    /// Each is shown once per device and then never, so reviewing the words
    /// otherwise means deleting the app, signing in again and walking the
    /// whole of setup — which is why the copy had never been seen end to
    /// end.
    ///
    /// It only clears flags: nothing is shown from here, because every
    /// coach mark belongs to a screen and each screen offers its own as it
    /// is visited, settle delay included. That is also what keeps the order
    /// a real first run has.
    ///
    /// Static, and on `.standard`, because the caller is a row in a
    /// settings list rather than a view that holds the coordinator — and
    /// the injected `defaults` exists for tests, which do not replay
    /// anything.
    static func replayAllLessons() {
        // The flags live in `UserDefaults`, so a throwaway coordinator is a
        // perfectly good way to reach them — and it keeps one
        // implementation of "arm everything" rather than a second copy that
        // could drift from the shipping one.
        FTUXCoordinator().replayAll()
    }
}
#endif
