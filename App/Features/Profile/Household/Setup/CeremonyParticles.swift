import SwiftUI

// The travelling light between the two phones, split out of
// `HouseholdCeremonyView.swift` for the project's file-length lint. A whole
// view of its own rather than an arbitrary cut: the ceremony decides *which
// way* the data is moving, and this decides what that looks like.

/// Light travelling between the two phones.
///
/// Driven by `TimelineView(.animation)` and pure arithmetic on the clock
/// rather than by animated state: there are two dozen of these, each on its
/// own offset, and giving every one its own `@State` plus a repeating
/// animation is two dozen animation drivers SwiftUI has to keep in step. One
/// clock, twenty-four positions computed from it, no state at all.
struct CeremonyParticles: View {
    let direction: HouseholdCeremonyPhase.Direction
    let tint: Color

    private static let count = 24
    private static let period: Double = 2.2

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { drawing, size in
                guard direction != .local else { return }
                let now = context.date.timeIntervalSinceReferenceDate

                for index in 0..<Self.count {
                    // A stable pseudo-random lane and phase per particle, so
                    // the stream looks scattered but never re-scatters
                    // between frames.
                    let seed = Double(index)
                    let lane = (sin(seed * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1).magnitude
                    let offset = (sin(seed * 78.233) * 12345.678).truncatingRemainder(dividingBy: 1).magnitude

                    var progress = ((now / Self.period) + offset).truncatingRemainder(dividingBy: 1)
                    if direction == .inbound { progress = 1 - progress }

                    let originX = size.width * (0.12 + lane * 0.76)
                    let originY = size.height * progress
                    // Fade in and out at both ends so nothing pops into
                    // existence at the edge of the canvas.
                    let fade = sin(progress * .pi)
                    let radius = 1.5 + lane * 2

                    drawing.fill(
                        Path(
                            ellipseIn: CGRect(
                                x: originX - radius, y: originY - radius,
                                width: radius * 2, height: radius * 2
                            )
                        ),
                        with: .color(tint.opacity(0.15 + fade * 0.75))
                    )
                }
            }
        }
        .blur(radius: 0.6)
        .animation(AppTheme.Motion.colorSafe, value: direction)
        .accessibilityHidden(true)
    }
}
