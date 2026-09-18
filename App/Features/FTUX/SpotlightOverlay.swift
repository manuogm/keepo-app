import KeepoCore
import SwiftUI

/// A coach mark: the screen dimmed, a hole cut around one control, and a
/// card pointing at it.
///
/// **Every lesson Keepo teaches arrives this way.** Each one is a gesture
/// on one specific control — swipe the banner, drag a row, long-press a
/// widget, press Add — and a popover that sits *near* something cannot say
/// *this one*. TipKit did the rest of the job well (eligibility, pacing,
/// persistence) and was dropped anyway, because the single thing it cannot
/// do is the thing every one of these lessons needs.
///
/// **The hole is a hole in the touch surface too.** Hit testing uses the
/// same even-odd path the scrim is drawn with, so the control underneath
/// stays live: the banner can be swiped, the account row can be dragged,
/// Add can be pressed — while the coach mark is still up. A lesson about a
/// gesture that will not let you perform the gesture is a screenshot.
struct SpotlightOverlay: View {
    /// Where to cut. In the overlay's own coordinate space, resolved by the
    /// caller from an `.ftuxAnchor()` further down the hierarchy.
    let cutout: CGRect
    let lesson: FTUXLesson
    let onDismiss: () -> Void

    /// Enough that the cut-out reads as a highlight around the control
    /// rather than as a crop of it.
    private static let padding: CGFloat = 8
    private static let pointerWidth: CGFloat = 18
    private static let pointerHeight: CGFloat = 9

    var body: some View {
        ZStack(alignment: .topLeading) {
            scrim
            // **The card takes no touches at all**, and that is what makes
            // the hole work. It is laid out by a `GeometryReader` filling
            // the screen, and a `GeometryReader` hit-tests its whole frame
            // — so with the card live, every touch in the hole was landing
            // on the layer above the scrim instead of on the banner
            // underneath (measured: the scope swipe did nothing until this
            // line existed). Taps on the card fall through to the scrim,
            // which is where dismissal belongs anyway; the card can never
            // overlap the hole, so nothing is lost.
            bubble.allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(lesson.title). \(lesson.message)")
        .accessibilityHint("Tap anywhere to dismiss")
        .accessibilityAddTraits(.isModal)
    }

    // MARK: - Scrim

    /// Even-odd fill rather than `.blendMode(.destinationOut)`: the hole has
    /// to be a hole in a *shape*, so the tap target and the drawing agree,
    /// and a destination-out composite would need its own compositing group
    /// to avoid punching through the app underneath it as well.
    ///
    /// That agreement is the whole trick here — the same shape is handed to
    /// `contentShape`, so a touch inside the hole misses this layer
    /// entirely and lands on the control being taught.
    private var scrim: some View {
        let shape = SpotlightScrim(hole: hole, radius: holeRadius)
        return shape
            .fill(Color.black.opacity(AppTheme.Opacity.scrim), style: FillStyle(eoFill: true))
            .contentShape(shape, eoFill: true)
            // One gesture, anywhere outside the hole: there is nothing to do
            // here but understand it, so anything that looks like "go on
            // then" has to work.
            .onTapGesture(perform: onDismiss)
    }

    private var hole: CGRect {
        cutout.insetBy(dx: -Self.padding, dy: -Self.padding)
    }

    /// A circular control gets a circular hole. Anything wide — the banner,
    /// an account row — takes the app's own surface radius, because a
    /// stadium around a full-width row would read as a pill rather than as
    /// a highlight of the row.
    private var holeRadius: CGFloat {
        let isRound = hole.width < hole.height * 1.2
        return isRound ? hole.height / 2 : AppTheme.Radius.surface
    }

    // MARK: - Bubble

    /// The card, placed on whichever side of the hole has the room.
    ///
    /// Sides rather than a fixed "below": the banner is at the top of the
    /// screen and the Add button is at the bottom, and a card below the
    /// latter would be off the display. Measured against the midpoint of
    /// the screen rather than against the card's own height, which is not
    /// known until it has been laid out — and a placement that depends on a
    /// measurement taken a pass late is a card that visibly jumps.
    private var bubble: some View {
        GeometryReader { proxy in
            let below = placesBelow(in: proxy.size)
            VStack(spacing: 0) {
                if below { pointer(pointsUp: true, in: proxy.size) }
                card
                if !below { pointer(pointsUp: false, in: proxy.size) }
            }
            .padding(.horizontal, AppTheme.Spacing.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: below ? .top : .bottom)
            .padding(.top, below ? hole.maxY : 0)
            .padding(.bottom, below ? 0 : proxy.size.height - hole.minY)
        }
    }

    private func placesBelow(in size: CGSize) -> Bool {
        hole.midY < size.height / 2
    }

    /// **Full width, not a column of prose.** It used to be capped at
    /// `proseWidth`, which is right for a paragraph and wrong for this: the
    /// title wrapped onto two lines with a hand's width of empty card
    /// beside it, and the scope lesson's three rows had nowhere to put a
    /// description. A coach mark is read once, at a glance, and the widest
    /// line it has is the one that should fit.
    private var card: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            // `ScopeGlyph`, not `Label`, because a lesson's symbol is
            // either an SF Symbol or one of Keepo's own `icon-` assets and
            // the card should not care which. Drawn in the title's ink at
            // the title's size: a coach mark has one voice, and a tinted
            // glyph twice the height of the words is a second one.
            HStack(spacing: AppTheme.Spacing.s) {
                ScopeGlyph(name: lesson.symbol, size: AppTheme.Size.glyphSmall)
                    .font(AppTheme.Typography.bodyEmphasis)
                Text(lesson.title)
                    // One line. At full width every title fits, and the
                    // scale factor is the floor under a large Dynamic Type
                    // size rather than the normal case.
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .font(AppTheme.Typography.bodyEmphasis)
            .foregroundStyle(AppTheme.Palette.textPrimary)

            Text(lesson.message)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Empty for most lessons; the list half of the two whose
            // message is a lead-in. Shared with "Show Me Around" so the
            // page and the card cannot say different amounts.
            FTUXLessonDetail(lesson: lesson)
                .padding(.top, AppTheme.Spacing.xxs)

            Text("Tap anywhere to continue")
                .font(AppTheme.Typography.nano)
                .foregroundStyle(AppTheme.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.Spacing.l)
        .background(AppTheme.Palette.bgSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card))
        .elevation(.floating)
    }

    /// Lines the card's pointer up with the middle of the hole, clamped so
    /// it never slides past the card's own corner radius — the Add button
    /// sits in the corner of the screen, so an unclamped pointer would be
    /// drawn off the end of the card it belongs to.
    private func pointer(pointsUp: Bool, in size: CGSize) -> some View {
        let cardWidth = size.width - 2 * AppTheme.Spacing.l
        let lowest = AppTheme.Radius.card
        let highest = max(lowest, cardWidth - AppTheme.Radius.card - Self.pointerWidth)
        let centred = hole.midX - AppTheme.Spacing.l - Self.pointerWidth / 2
        return SpotlightPointer(pointsUp: pointsUp)
            .fill(AppTheme.Palette.bgSurface)
            .frame(width: Self.pointerWidth, height: Self.pointerHeight)
            .offset(x: min(max(centred, lowest), highest))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Shapes

/// The screen with a hole in it. Filled even-odd, and handed to
/// `contentShape` so the drawing and the touch surface cannot disagree.
private struct SpotlightScrim: Shape {
    let hole: CGRect
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.addRect(rect)
            path.addRoundedRect(in: hole, cornerSize: CGSize(width: radius, height: radius))
        }
    }
}

private struct SpotlightPointer: Shape {
    let pointsUp: Bool

    func path(in rect: CGRect) -> Path {
        Path { path in
            if pointsUp {
                path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            } else {
                path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            }
            path.closeSubpath()
        }
    }
}

// MARK: - Anchoring

/// What a coach mark should cut around: the anchor, and how far past that
/// view the thing the user actually sees extends.
///
/// `Anchor<CGRect>` rather than a resolved frame: a view does not know what
/// coordinate space the overlay will be resolved in, and an anchor is the
/// one thing SwiftUI can translate correctly across that gap.
struct FTUXTarget {
    let anchor: Anchor<CGRect>
    /// **For a tile the view does not draw.** An inset-grouped `List` draws
    /// each row's white tile itself, around content that is inset inside
    /// it — so the transaction row's own bounds are a good deal smaller
    /// than the card the user is being told to swipe. Measured, not
    /// guessed; zero everywhere the view and its tile are the same thing.
    var expansion: CGSize = .zero
}

/// Where each coach mark should cut, published by the views they are about
/// and keyed by `FTUXLesson.id`.
struct FTUXAnchorKey: PreferenceKey {
    static let defaultValue: [String: FTUXTarget] = [:]

    static func reduce(value: inout [String: FTUXTarget], nextValue: () -> [String: FTUXTarget]) {
        // First wins, per lesson. Four tabs each render a scope banner, and
        // a tab that is merely *prepared* rather than visible would
        // otherwise be able to move the hole.
        value.merge(nextValue()) { current, _ in current }
    }
}

extension View {
    /// Marks this view as the thing `lesson`'s coach mark points at.
    ///
    /// Takes an optional so a call site inside a `ForEach` can say "this
    /// row, not the others" without branching the row itself into two
    /// different view types.
    ///
    /// **`transform`, not `anchorPreference`, and that is load-bearing.**
    /// Setting a preference outright replaces whatever the subtree beneath
    /// already published under the same key — so the scope banner, which
    /// anchors itself *and* contains the eye that anchors the privacy
    /// lesson, was silently erasing the eye's anchor on its way past.
    /// Measured: the coach mark went `visible` and nothing was drawn,
    /// because the overlay had no rectangle to cut. Transforming adds this
    /// lesson's entry and leaves every other one alone.
    func ftuxAnchor(_ lesson: FTUXLesson?, expandedBy expansion: CGSize = .zero) -> some View {
        transformAnchorPreference(key: FTUXAnchorKey.self, value: .bounds) { targets, anchor in
            guard let lesson else { return }
            targets[lesson.id] = FTUXTarget(anchor: anchor, expansion: expansion)
        }
    }
}

/// Resolves the anchor and draws the coach mark over the whole app.
///
/// **`lesson` is a plain argument, not read from the coordinator inside the
/// closure**, and that is load-bearing. `overlayPreferenceValue`'s builder
/// runs in its own update pass, so an `@Observable` property read only in
/// there does not reliably register as a dependency of the view's body —
/// the flag flipped and nothing redrew, which showed up as "Show me around"
/// replaying the spotlight to a screen that never changed. Read at the call
/// site, in `body`, the dependency is ordinary.
private struct SpotlightModifier: ViewModifier {
    let lesson: FTUXLesson?
    let onDismiss: () -> Void
    let onUnanchored: () -> Void

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(FTUXAnchorKey.self) { targets in
                let target = lesson.flatMap { targets[$0.id] }
                GeometryReader { proxy in
                    if let lesson, let target {
                        SpotlightOverlay(
                            cutout: proxy[target.anchor].insetBy(
                                dx: -target.expansion.width, dy: -target.expansion.height
                            ),
                            lesson: lesson,
                            onDismiss: onDismiss
                        )
                    }
                }
                .ignoresSafeArea()
                // **A coach mark with nothing to point at is an unusable
                // screen**: it dims nothing, draws nothing, and cannot be
                // tapped away. It happens when the control disappears from
                // under it — the inbox drawer closing as its last item
                // syncs, a list reloading empty — so the coordinator is
                // told to put this one back rather than leave the user
                // holding an invisible modal. The beat is for the ordinary
                // case where the anchor simply has not been published yet.
                .task(id: lesson.map { targets[$0.id] == nil }) {
                    guard let lesson, targets[lesson.id] == nil else { return }
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    onUnanchored()
                }
            }
            .animation(AppTheme.Motion.standard, value: lesson)
    }
}

extension View {
    func spotlight(
        _ lesson: FTUXLesson?,
        onDismiss: @escaping () -> Void,
        onUnanchored: @escaping () -> Void
    ) -> some View {
        modifier(
            SpotlightModifier(lesson: lesson, onDismiss: onDismiss, onUnanchored: onUnanchored)
        )
    }
}
