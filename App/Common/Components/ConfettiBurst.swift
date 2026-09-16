import SwiftUI

/// A single radial burst of confetti, fired once when `isActive` becomes
/// true and never again.
///
/// Drawn *behind* whatever it celebrates: the pieces start under the centre
/// and travel outward, so the mark in front of them reads as the source of
/// the burst rather than something the confetti happens to be flying past.
///
/// **Nothing moves under Reduce Motion.** Sixty pieces crossing the screen
/// is precisely the class of animation that setting exists to suppress, and
/// the screen this decorates says everything it needs to without it. The
/// haptic is left to the caller and should still fire — that is feedback,
/// not motion.
struct ConfettiBurst: View {
    var isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Generated once and held, not recomputed per render: the randomness
    /// is the *shape* of this particular burst, and re-rolling it on every
    /// body evaluation would make the pieces twitch between frames instead
    /// of fly.
    @State private var pieces = Piece.burst()
    @State private var progress: CGFloat = 0

    /// Long enough to read as a burst rather than a flicker, short enough
    /// that the button underneath is never waiting on it.
    private static let duration: TimeInterval = 1.6
    /// A little gravity, applied against progress² so it bends the arcs
    /// late. Without it the pieces travel in perfectly straight radial
    /// lines and the whole thing reads as a diagram of an explosion.
    private static let fall: CGFloat = 140

    var body: some View {
        GeometryReader { proxy in
            let reach = max(proxy.size.width, proxy.size.height) / 2
            ZStack {
                ForEach(pieces) { piece in
                    shape(for: piece)
                        .rotationEffect(.degrees(piece.spin * Double(progress)))
                        .offset(
                            x: cos(piece.angle) * reach * piece.reach * progress,
                            y: sin(piece.angle) * reach * piece.reach * progress
                                + Self.fall * progress * progress
                        )
                        .opacity(pieceOpacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        // Decoration over a screen with a button on it: it must never be
        // the thing a tap lands on.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .opacity(reduceMotion ? 0 : 1)
        .onChange(of: isActive, initial: true) { _, active in
            guard active, !reduceMotion, progress == 0 else { return }
            withAnimation(.easeOut(duration: Self.duration)) { progress = 1 }
        }
    }

    @ViewBuilder
    private func shape(for piece: Piece) -> some View {
        if piece.isRound {
            Circle()
                .fill(piece.color)
                .frame(width: piece.width, height: piece.width)
        } else {
            // A pill rather than a rectangle: at six points across, a
            // corner radius small enough to read as a corner is smaller
            // than a pixel on most of the devices this runs on.
            Capsule()
                .fill(piece.color)
                .frame(width: piece.width, height: piece.height)
        }
    }

    /// Full through most of the flight, then out — pieces that simply stop
    /// at the screen edge look like they hit a wall.
    private var pieceOpacity: Double {
        progress < 0.7 ? 1 : Double(max(0, (1 - progress) / 0.3))
    }

    struct Piece: Identifiable {
        let id = UUID()
        let angle: Double
        /// Fraction of the view's half-diagonal this piece travels. The
        /// spread is what stops the burst arriving as a single ring.
        let reach: CGFloat
        let width: CGFloat
        let height: CGFloat
        let spin: Double
        let color: Color
        let isRound: Bool

        /// Green, because this fires under a green checkmark and a burst in
        /// six unrelated colours would read as a party rather than as the
        /// same "done" the mark is already saying. Two greens and the brand
        /// amber for lift, weighted so the amber stays a minority.
        static let palette: [Color] = [
            AppTheme.Palette.statusPositive,
            AppTheme.Palette.statusPositive,
            AppTheme.Palette.cashflowIncome,
            AppTheme.Palette.cashflowIncome,
            AppTheme.Palette.brandPrimary
        ]

        static func burst(count: Int = 56) -> [Piece] {
            (0..<count).map { index in
                // Evenly spaced angles with a jitter, rather than pure
                // random: at this count pure random leaves visible clumps
                // and gaps, and the eye reads a gap in a radial burst as a
                // rendering fault rather than as chance.
                let spoke = (Double(index) / Double(count)) * 2 * .pi
                return Piece(
                    angle: spoke + Double.random(in: -0.22...0.22),
                    reach: CGFloat.random(in: 0.45...1.05),
                    width: CGFloat.random(in: (AppTheme.Size.dot * 0.6)...(AppTheme.Size.dot * 1.1)),
                    height: CGFloat.random(in: AppTheme.Size.dot...(AppTheme.Size.dot * 1.8)),
                    spin: Double.random(in: -540...540),
                    color: palette.randomElement() ?? AppTheme.Palette.statusPositive,
                    isRound: Bool.random()
                )
            }
        }
    }
}
