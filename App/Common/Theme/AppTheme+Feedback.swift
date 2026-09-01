import SwiftUI

// MARK: - Haptics

extension AppTheme {
    /// Everything the app says through the Taptic Engine, named by what the
    /// user just did rather than by how hard it buzzes.
    ///
    /// The dashboard already had a vocabulary (`DashboardHaptics`) and it was
    /// right about the important thing: **haptics are a language, and an app
    /// that vibrates at everything says nothing.** What it could not do was
    /// keep the rest of the app in step — outside the canvas there were
    /// fourteen bare `.selection` calls and two one-off `.impact` literals
    /// with hand-tuned intensities that no longer matched anything.
    ///
    /// Two layers on purpose. `Level` is the **strength ramp** — one number
    /// per step, and moving a step moves every intent that sits on it.
    /// `Feedback`'s members are the **intents**, and a call site only ever
    /// names one of those: a keypad says `.typing`, never `0.4`.
    enum Feedback {
        // MARK: Typing

        /// A key on a keypad. **Softest thing in the vocabulary**, because it
        /// is the only one that fires in a burst — a four-digit amount is
        /// four of these inside a second, and anything heavier reads as the
        /// phone rattling rather than as keys.
        static let typing = SensoryFeedback.impact(
            flexibility: .soft, intensity: Level.whisper
        )

        // MARK: Discrete choices

        /// Moving between options in a segmented control, a picker, a tab, a
        /// filter chip. The system's own `.selection`, unchanged — it is
        /// already the lightest detent iOS has and it is what a user's other
        /// apps use for the same gesture.
        static let selection = SensoryFeedback.selection

        /// Flipping a switch, expanding a row — a binary that stays flipped.
        /// Heavier than `selection` because there is no third option to move
        /// on to; this one landed somewhere.
        static let toggle = SensoryFeedback.impact(
            flexibility: .soft, intensity: Level.firm
        )

        // MARK: Buttons

        /// A tap on a control that *does* something — the app's primary
        /// action, a sheet's commit button.
        ///
        /// Deliberately not applied to every button in the app. A row that
        /// opens a sheet already reports itself visually
        /// (`PressableRowButtonStyle`), and a list where every row buzzed
        /// would drown out the ones that matter.
        static let buttonPress = SensoryFeedback.impact(
            weight: .light, intensity: Level.light
        )

        // MARK: Modes

        /// Entering a mode the whole screen is now in — the dashboard's edit
        /// mode. Shares `lift`'s weight deliberately: both are the moment
        /// something becomes movable, and they should feel like the same
        /// kind of event even though one is a screen and one is a tile.
        static let modeChange = SensoryFeedback.impact(
            weight: .medium, intensity: Level.full
        )

        // MARK: Drag & drop

        /// A widget has left the catalogue and is in hand.
        ///
        /// The load-bearing one. A drag out of the catalogue is a system drag
        /// session, and UIKit stretches its press-and-hold when the source
        /// sits inside a scroll view so scrolling can still win — which
        /// leaves a noticeable, silent wait where the user cannot tell
        /// whether the press registered. The duration is not ours to
        /// shorten; the acknowledgement is.
        static let lift = SensoryFeedback.impact(
            weight: .medium, intensity: Level.full
        )

        /// Something already on the grid has been picked up. Lighter than a
        /// `lift`: less of a commitment, and it happens far more often.
        static let pickUp = SensoryFeedback.impact(
            weight: .light, intensity: Level.full
        )

        /// The landing cell moved. The tick is what makes a drag feel like it
        /// is snapping to something rather than floating.
        static let snap = SensoryFeedback.selection

        /// It landed. Same weight as `pickUp` — the gesture opened and closed
        /// with the same sound.
        static let drop = SensoryFeedback.impact(
            weight: .light, intensity: Level.full
        )

        /// Crossing a limit a gesture cannot pass, or one behind which it
        /// ends with nothing happening — the dashboard's trash.
        ///
        /// **Rigid, where the rest of this vocabulary is soft.** It should
        /// feel like hitting something rather than like settling onto it.
        static let boundary = SensoryFeedback.impact(
            flexibility: .rigid, intensity: Level.firm
        )

        /// A swipe that has committed and is springing to its new resting
        /// place — the scope banner's carousel.
        static let swipeCommit = SensoryFeedback.impact(
            flexibility: .soft, intensity: Level.firm
        )

        // MARK: Outcomes

        /// A write landed. The system's notification pattern, not an impact —
        /// it is a distinct rhythm rather than a harder tap, which is what
        /// makes it readable without looking at the screen.
        static let success = SensoryFeedback.success
        /// Something needs attention but nothing was lost.
        static let warning = SensoryFeedback.warning
        /// A write failed.
        static let failure = SensoryFeedback.error
    }
}

// MARK: - Strength

extension AppTheme.Feedback {
    /// How hard, in four steps.
    ///
    /// Calibrated against what was already in the app rather than
    /// invented: `firm` is the 0.8 the scope banner's swipe and the
    /// dashboard's trash boundary had both independently landed on.
    ///
    /// The ramp is not linear and should not be. Below about 0.3 the
    /// Taptic Engine stops being felt reliably through a case, and the
    /// gap between 0.8 and 1.0 is the one a user actually reads as
    /// "that was different".
    enum Level {
        /// 0.4 — a keystroke. Repeats many times per second, so it has to
        /// be under the threshold where repetition becomes buzzing.
        static let whisper: Double = 0.4
        /// 0.6 — a deliberate tap on a control.
        static let light: Double = 0.6
        /// 0.8 — a landmark inside a gesture: a swipe committing, a drag
        /// crossing a boundary.
        static let firm: Double = 0.8
        /// 1.0 — a state change the user cannot undo by letting go.
        static let full: Double = 1.0
    }
}
