import KeepoCore
import SwiftUI

/// The peak: two phones, held together, building a household.
///
/// Everything on this screen is driven by `HouseholdSetupCoordinator`, which
/// only advances a step once the work behind it has actually returned — so
/// the choreography is a report on real progress rather than a loading
/// animation with a timer. See that type's own note.
///
/// ## What the motion is saying
///
/// Three layers, and each one means something specific:
///
///   * **The house fills.** One thing being built, from nothing to nearly
///     whole. It stops at 90% while the owner reviews the report, because the
///     household genuinely is not finished until they press Finish — filling
///     it and then waiting would be the animation lying and then making the
///     user sit through it.
///   * **Particles cross the gap.** They travel upward on a step that is
///     sending and downward on one that is receiving, so the direction on one
///     phone is the mirror of the direction on the other. Two people watching
///     side by side see data leave one screen and arrive on the next.
///   * **The screen breathes.** A slow glow behind the house, pulsing once
///     per step, tied to the same haptic. It is what makes the phone feel
///     alive in the hand rather than busy.
///
/// A merge step has no direction and the particles go still — nothing is
/// crossing, the work is happening here. That stillness is the reason the
/// travel reads as travel the rest of the time.
struct HouseholdCeremonyView: View {
    let session: SessionStore
    let avatars: AvatarStore
    let coordinator: HouseholdSetupCoordinator
    var onBuilt: () -> Void

    @State private var isShowingReport = false
    @State private var hasCelebrated = false

    /// A very dark shade of the household colour, per the spec — the same hue
    /// the scope banner uses, taken almost to black so the filling house and
    /// the travelling light are the only things on screen with any luminance.
    private var backdrop: Color {
        PublicSchema.AccountScope.household.tint.shifted(saturation: 0.18, brightness: -0.66)
    }

    private var fillColor: Color { PublicSchema.AccountScope.household.tint }

    var body: some View {
        ZStack {
            backdrop.ignoresSafeArea()
            glow
            content
        }
        .preferredColorScheme(.dark)
        // Every step lands as a tap. The vocabulary is deliberate: `.toggle`
        // for the eight ordinary steps and `.success` for the finish, so the
        // end of the ceremony is felt as different rather than just as the
        // ninth of the same thing.
        .sensoryFeedback(AppTheme.Feedback.toggle, trigger: coordinator.phaseTick)
        .sensoryFeedback(AppTheme.Feedback.success, trigger: hasCelebrated)
        .onChange(of: coordinator.outcome) { _, outcome in
            switch outcome {
            case .readyForReport:
                isShowingReport = true
            case .finished:
                hasCelebrated = true
                Task {
                    // Long enough to read "You belong to the same household
                    // now" and see the house complete, short enough that it
                    // does not become a screen the user has to dismiss.
                    try? await Task.sleep(for: .seconds(2.6))
                    onBuilt()
                }
            case .running, .waitingForOwner, .failed:
                break
            }
        }
        .fullScreenCover(isPresented: $isShowingReport) {
            HouseholdReportFlow(
                session: session,
                myAvatar: avatars.image,
                // The bytes that came over the peer link. The report runs
                // before the household is final, so `avatars_select` still
                // refuses the other member's folder — this is the only copy of
                // their face that exists on this phone yet.
                peerAvatar: coordinator.peer?.avatarJPEG.flatMap(UIImage.init(data:)),
                peerName: coordinator.peer?.resolvedName,
                onFinish: {
                    isShowingReport = false
                    await coordinator.finish()
                }
            )
        }
    }

    // MARK: - Layers

    @ViewBuilder
    private var content: some View {
        if case .failed(let message) = coordinator.outcome {
            failure(message)
        } else {
            ceremony
        }
    }

    private var ceremony: some View {
        VStack(spacing: AppTheme.Spacing.xxl) {
            Spacer()

            ZStack {
                CeremonyParticles(direction: particleDirection, tint: fillColor)
                    .frame(width: 220, height: 320)
                house
            }

            VStack(spacing: AppTheme.Spacing.s) {
                // How far along, as a number, and the headline of the screen.
                // The filling house says "something is happening"; this says
                // how much is left, which is the question anybody watching a
                // progress animation is actually asking — so it leads, and
                // the step name explains it rather than the other way round.
                // It holds at 90% while the owner reviews the report — the
                // same truth the house's own fill tells.
                Text(fill.formatted(.percent.precision(.fractionLength(0))))
                    // `numberFont` rather than a raw `.font`: it carries the
                    // `@ScaledMetric` that makes every display figure in the
                    // app grow together under Dynamic Type.
                    .numberFont(AppTheme.Typography.Number.balance, weight: .semibold)
                    .foregroundStyle(AppTheme.Palette.textOnAccent)
                    .contentTransition(.numericText())
                    .animation(AppTheme.Motion.colorSafe, value: fill)

                Text(isComplete ? "Household built" : "Building Household")
                    .font(AppTheme.Typography.sectionTitle)
                    .foregroundStyle(AppTheme.Palette.textOnAccent)

                Text(caption)
                    .font(AppTheme.Typography.label)
                    .foregroundStyle(AppTheme.Palette.textOnAccent.opacity(AppTheme.Opacity.muted))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    // The step name is the one thing on screen that changes
                    // every half-second. A cross-fade rather than a slide:
                    // the words are being replaced in place, not scrolled
                    // through.
                    .id(caption)
                    .transition(.opacity)
                    .animation(AppTheme.Motion.colorSafe, value: caption)
            }
            .padding(.horizontal, AppTheme.Spacing.xxl)

            Spacer()
        }
    }

    /// White, filling with the household green from the floor up.
    private var house: some View {
        let side: CGFloat = 140
        return ZStack {
            KeepoIcon(name: "icon-home-filled", size: side)
                .foregroundStyle(AppTheme.Palette.textOnAccent.opacity(0.22))

            KeepoIcon(name: "icon-home-filled", size: side)
                .foregroundStyle(fillColor)
                .mask(alignment: .bottom) {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle().frame(height: side * fill)
                    }
                    .frame(width: side, height: side)
                }
                // The fill is the one thing that must never jump: it is the
                // progress bar of the whole ceremony, and a spring on it
                // would overshoot past 100% at the finish.
                .animation(.easeInOut(duration: 0.45), value: fill)

            KeepoIcon(name: "icon-home-filled", size: side)
                .foregroundStyle(AppTheme.Palette.textOnAccent)
                .opacity(isComplete ? 1 : 0)
                .scaleEffect(isComplete ? 1 : 0.9)
                .animation(.snappy(duration: 0.5), value: isComplete)
        }
        .frame(width: side, height: side)
        .accessibilityElement()
        .accessibilityLabel("Building your household")
        .accessibilityValue(caption)
    }

    /// A soft bloom behind everything, brightening once per step.
    private var glow: some View {
        RadialGradient(
            colors: [fillColor.opacity(0.38), .clear],
            center: .center,
            startRadius: 0,
            endRadius: 320
        )
        .scaleEffect(pulse)
        .animation(.easeInOut(duration: 0.55), value: coordinator.phaseTick)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: AppTheme.Spacing.l) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(AppTheme.Typography.screenTitle)
                .foregroundStyle(AppTheme.Palette.textOnAccent)
            Text("The household wasn't built")
                .font(AppTheme.Typography.sectionTitle)
                .foregroundStyle(AppTheme.Palette.textOnAccent)
            Text(message)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textOnAccent.opacity(AppTheme.Opacity.muted))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Close") { onBuilt() }
                .font(AppTheme.Typography.labelEmphasis)
                .foregroundStyle(AppTheme.Palette.textOnAccent)
                .padding(.horizontal, AppTheme.Spacing.xl)
                .padding(.vertical, AppTheme.Spacing.m)
                .background(
                    AppTheme.Palette.textOnAccent.opacity(AppTheme.Opacity.fill), in: Capsule()
                )
                .buttonStyle(.plain)
        }
        .padding(.horizontal, AppTheme.Spacing.xxl)
    }

    // MARK: - Derived

    private var isComplete: Bool { coordinator.outcome == .finished }

    private var fill: Double {
        isComplete ? 1 : coordinator.fill
    }

    /// A slight, alternating swell rather than a value derived from progress:
    /// the glow is a heartbeat, and a heartbeat that grew steadily through
    /// the ceremony would read as a loading bar drawn in light.
    private var pulse: CGFloat {
        coordinator.phaseTick.isMultiple(of: 2) ? 1 : 1.08
    }

    private var caption: String {
        switch coordinator.outcome {
        case .finished:
            return "You belong to the same household now."
        case .waitingForOwner:
            return "Waiting for \(coordinator.peer?.resolvedName ?? "the household owner") to finish the setup"
        case .readyForReport, .running, .failed:
            return coordinator.phase.title
        }
    }

    private var particleDirection: HouseholdCeremonyPhase.Direction {
        switch coordinator.outcome {
        // Nothing is crossing while one person reads a report. Still
        // particles are how the other phone says "it is not stuck, it is
        // waiting" without adding a second spinner.
        case .waitingForOwner, .finished, .readyForReport: return .local
        case .running, .failed: return coordinator.phase.direction
        }
    }
}

// MARK: - Particles

/// Light travelling between the two phones.
///
/// Driven by `TimelineView(.animation)` and pure arithmetic on the clock
/// rather than by animated state: there are two dozen of these, each on its
/// own offset, and giving every one its own `@State` plus a repeating
/// animation is two dozen animation drivers SwiftUI has to keep in step. One
/// clock, twenty-four positions computed from it, no state at all.
private struct CeremonyParticles: View {
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
