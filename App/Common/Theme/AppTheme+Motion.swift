import SwiftUI

// MARK: - Motion

extension AppTheme {
    /// How long anything on screen takes to move.
    ///
    /// The app had **eight** `.snappy` durations (0.18 through 0.32) and no
    /// rule for choosing between them: the Needs Review drawer opened in
    /// 0.28, the widget catalogue in 0.30, and the tab bar's selection in
    /// 0.22, and nothing anywhere said why. Two of the eight were real
    /// decisions — leaving edit mode was consistently 0.24 across all three
    /// ways of triggering it, and grid re-layout was consistently 0.32
    /// because tiles moving under a finger have to stay readable. The other
    /// six were the residue of writing each screen on its own day.
    ///
    /// Four tokens, and the fourth is the one that matters most.
    ///
    /// **`colorSafe` is not a taste call — it is a bug fix with a name.**
    /// `.snappy` is a spring, springs overshoot, and an overshoot on an
    /// *interpolated colour* has nowhere to go: it clamps at the end of the
    /// ramp and comes back, which reads as the mark flashing rather than as
    /// bounce. That cost the dashboard two visible defects — the chart's
    /// highlight flickering and the Cashflow toggle double-blinking — before
    /// anyone traced it. Anything whose animation is mostly a colour or an
    /// opacity change takes this token, and the type checker cannot enforce
    /// that, so the name has to.
    ///
    /// Three things are deliberately **not** here: the scope carousel's two
    /// `.spring(response:dampingFraction:)` values (a rejected drag damps
    /// harder than a committed one — that pairing is the gesture, not a
    /// duration), the edit-mode jiggle's randomised 0.13–0.17 period (no two
    /// tiles may stay in sync, so it must not be one number), and
    /// `AmountField`'s `.animation(nil,)`, which is suppression rather than
    /// motion.
    enum Motion {
        /// 0.20 — a small state flip that changes nothing's position: a
        /// selected segment, a tab, a highlighted chip, a search bar
        /// appearing. Absorbs the old 0.18 and 0.22.
        static let quick = Animation.snappy(duration: 0.2)

        /// The same 0.2, as a number — see `standardDuration` for why one
        /// of these exists at all.
        static let quickDuration: TimeInterval = 0.2

        /// 0.25 — **the default.** A view arriving, leaving, expanding or
        /// collapsing: a drawer, a disclosure row, a mode change, a sheet.
        /// Absorbs the old 0.24, 0.28 and most of 0.30.
        ///
        /// If you are unsure which token a new animation wants, it wants
        /// this one.
        static let standard = Animation.snappy(duration: 0.25)

        /// The same 0.25, as a number. For the one kind of caller that has
        /// to *sequence* against `standard` rather than merely use it —
        /// the category row, whose fill may only start once the tile it
        /// belongs to has finished travelling. Written twice in one place
        /// beats a literal 0.25 sitting in a view file, drifting the first
        /// time this token is ever retuned.
        static let standardDuration: TimeInterval = 0.25

        /// 0.32 — the dashboard grid settling into a new arrangement: a tile
        /// expanding, a drop committing, a widget added or removed.
        ///
        /// The slowest thing in the app, on purpose. Several tiles move at
        /// once and the user is tracking one of them; faster than this and
        /// the eye loses which tile was theirs.
        static let layout = Animation.snappy(duration: 0.32)

        /// 0.20, **no bounce** — for anything whose animation is mostly a
        /// colour or an opacity change. See the type's own note above: this
        /// is the token that exists because a spring here is a rendering
        /// bug, not a style.
        ///
        /// It still animates rather than cutting, unlike the Cashflow
        /// toggle, which resolved the same bug by dropping the transaction
        /// entirely: a chart highlight also rolls digits through
        /// `contentTransition(.numericText())`, and that needs one.
        static let colorSafe = Animation.easeInOut(duration: 0.2)

        /// A button's press state — **asymmetric, and that is the point.**
        /// Fast in (0.08) so the press registers on the first frame of the
        /// touch, before any `await`; gentle out (0.18) because a snap back
        /// on release looks twitchy.
        static func press(isPressed: Bool) -> Animation {
            isPressed ? .easeOut(duration: 0.08) : .easeOut(duration: 0.18)
        }
    }
}
