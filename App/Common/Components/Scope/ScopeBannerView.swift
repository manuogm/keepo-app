import KeepoCore
import SwiftUI

/// The top of every main screen: one full-bleed colour card per scope,
/// dragged horizontally to change which slice of the user's money the whole
/// app is computing for.
///
/// It replaces two separate controls — the top-left "…" scope menu and the
/// `.principal` title bar — with a single object, and that is the point.
/// Scope used to be a state you had to remember you were in; it is now the
/// surface the screen title sits on, so it cannot be missed. `session.scope`
/// is still the one source of truth, so the choice survives a tab switch
/// exactly as it did before.
///
/// **On the drag.** This is a hand-rolled `DragGesture` over an offset
/// `HStack`, not a paging `ScrollView`, because the requested feel is
/// something paging cannot express: the card resists at first and then,
/// past a point of no return, leaves on its own without waiting for the
/// finger to lift. `resisted(_:)` is the first half — the card moves as the
/// **1.6th power** of how far the finger has travelled, so an early
/// millimetre barely registers and a late one moves it a long way — and the
/// commit inside `onChanged` is the second: once past 30% of the width the
/// gesture stops being consulted at all and a spring finishes the journey.
/// At the ends of the carousel the exponent rises to 3.2 and nothing ever
/// commits, which is what makes "there is nothing that way" felt rather
/// than merely true.
///
/// The cards sit in a **deck**: a gap between them so the page shows through
/// as one leaves and the next arrives, and each one tilts and shrinks in
/// proportion to how far it is from resting — nothing at rest, most at the
/// halfway point of a swipe. Nothing is clipped, because the neighbours are
/// off-screen anyway and clipping is what would flatten the tilt back into
/// a rectangle.
///
/// The card also paints up behind the status bar, so the header has no hard
/// colour edge at the top of the screen. The whole carousel is pulled up by
/// the top safe-area inset and each card adds it back as padding, rather
/// than a band being drawn behind: a band that is not part of the card
/// cannot travel with it, and would leave a seam of the outgoing colour
/// across the status bar for the whole length of a swipe.
struct ScopeBannerView<Accessory: View, Filters: View>: View {
    let title: String
    let session: SessionStore
    /// Whether the caller's `filters` panel is showing. The panel is drawn
    /// as part of the banner — same colour, same width, tucked up behind the
    /// card by its own corner radius — so a screen's filters read as part of
    /// its header rather than as a toolbar underneath one.
    var isFiltersExpanded = false
    let onOpenProfile: () -> Void
    /// Rendered immediately before the privacy toggle. Home puts "Done"
    /// here while the dashboard is being rearranged; Transactions puts the
    /// toggle for its own `filters` panel.
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var filters: Filters

    @State private var width: CGFloat = 0
    @State private var dragOffset: CGFloat = 0
    /// Set the instant a drag passes the point of no return, and cleared
    /// when the finger lifts. While it is set the gesture is ignored: the
    /// card is already on its way and a finger that keeps moving (or
    /// wanders back) must not drag it off course.
    @State private var isCommitted = false
    @Environment(\.topSafeAreaInset) private var topSafeAreaInset

    private var scopes: [PublicSchema.AccountScope] { PublicSchema.AccountScope.carousel }
    /// Derived, never stored — `session.scope` is the source of truth, so a
    /// scope set from anywhere else lands this carousel on the right card
    /// with nothing to keep in step.
    private var index: Int { scopes.firstIndex(of: session.scope) ?? 0 }
    private var cardWidth: CGFloat { max(width, 1) }
    /// The page the user sees between two cards mid-swipe.
    private var gap: CGFloat { 14 }
    /// One card plus one gap — the distance the deck travels per scope.
    private var step: CGFloat { cardWidth + gap }

    var body: some View {
        VStack(spacing: 0) {
            carousel
            if isFiltersExpanded {
                filtersPanel
            }
        }
        .shadow(color: .black.opacity(0.13), radius: 10, y: 5)
        .animation(.snappy(duration: 0.28), value: isFiltersExpanded)
    }

    // MARK: - Carousel

    private var carousel: some View {
        HStack(spacing: gap) {
            ForEach(Array(scopes.enumerated()), id: \.element) { position, scope in
                card(scope)
                    .frame(width: cardWidth)
                    .rotationEffect(tilt(at: position))
                    .scaleEffect(shrink(at: position))
            }
        }
        .frame(width: cardWidth, alignment: .leading)
        .offset(x: -CGFloat(index) * step + dragOffset)
        // Deliberately unclipped: every neighbour is off the screen's own
        // edge already, and a clip is exactly what would cut the tilt of the
        // card being dragged back into a rectangle.
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { pageDots }
        .contentShape(Rectangle())
        .gesture(swipe)
        .padding(.top, -topSafeAreaInset)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func card(_ scope: PublicSchema.AccountScope) -> some View {
        HStack(spacing: 12) {
            Button(action: onOpenProfile) {
                ProfileAvatarView(email: session.userEmail, size: 40, onColor: true)
            }
            .buttonStyle(.pressableCard)
            .accessibilityLabel("Open profile")

            HStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.white)
                if let badge = scope.badgeTitle {
                    ScopeBadge(title: badge, icon: scope.icon)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            Spacer(minLength: 4)

            accessory
            PrivacyToggleButton(session: session, tint: .white, font: .body)
                .frame(width: 32, height: 32)
        }
        .padding(.horizontal, 16)
        .padding(.top, topSafeAreaInset + 12)
        // Leaves the room the page dots are drawn into, so they sit inside
        // the card rather than on a strip of their own below it.
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A shade darker at the top. Small enough that the card still reads
        // as one colour — it is depth, not decoration, and the flat-colour
        // rule everywhere else in the app is untouched.
        .background(
            LinearGradient(
                colors: [scope.tint.shifted(brightness: -0.07), scope.tint],
                startPoint: .top, endPoint: .bottom
            ),
            in: UnevenRoundedRectangle(bottomLeadingRadius: 24, bottomTrailingRadius: 24, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(scope.title) scope")
    }

    /// The current scope's dot is a **pill**, not a bigger circle: length is
    /// what reads as "you are here" at a glance, where a size difference
    /// between two dots has to be compared to be seen.
    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(scopes, id: \.self) { scope in
                let isCurrent = scope == session.scope
                Capsule()
                    .fill(Color.white.opacity(isCurrent ? 0.95 : 0.38))
                    .frame(width: isCurrent ? 18 : 6, height: 6)
            }
        }
        .padding(.bottom, 10)
        .animation(.snappy(duration: 0.25), value: session.scope)
        .accessibilityHidden(true)
    }

    /// Tucked up behind the card by the card's own corner radius, so it
    /// reads as something the header opened rather than a toolbar parked
    /// beneath one. A **shade darker** than the card: same family, clearly a
    /// second surface — at the identical colour the two merged into one
    /// tall block and the card stopped being a card.
    private var filtersPanel: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 24)
            filters
                .padding(.horizontal, 16)
                // Breathing room under the card's edge — without it the
                // first row of controls sits flush against the header and
                // the panel reads as a continuation of it rather than as a
                // drawer it opened.
                .padding(.top, 10)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
        .background(
            session.scope.panelTint,
            in: UnevenRoundedRectangle(bottomLeadingRadius: 24, bottomTrailingRadius: 24, style: .continuous)
        )
        .padding(.top, -24)
        .zIndex(-1)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Gesture

    /// How far a card is from home, as a fraction of one step: 0 for the
    /// card at rest, ±1 for its neighbours. Everything about the deck's look
    /// is a function of this one number.
    private func travel(at position: Int) -> CGFloat {
        guard width > 1 else { return 0 }
        let distance = CGFloat(position - index) * step + dragOffset
        return max(-1, min(1, distance / step))
    }

    private func tilt(at position: Int) -> Angle {
        .degrees(Double(travel(at: position)) * 2.5)
    }

    private func shrink(at position: Int) -> CGFloat {
        1 - abs(travel(at: position)) * 0.035
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isCommitted, width > 1 else { return }
                let raw = value.translation.width
                dragOffset = resisted(raw)
                guard abs(raw) > step * 0.30, let target = neighbour(towards: raw) else { return }
                commit(to: target)
            }
            .onEnded { value in
                guard !isCommitted else {
                    isCommitted = false
                    return
                }
                // Not far enough to break free, but flicked hard enough that
                // it would have been — `predictedEndTranslation` is the same
                // number a scroll view uses to decide a fling.
                if abs(value.predictedEndTranslation.width) > step * 0.5,
                   let target = neighbour(towards: value.predictedEndTranslation.width) {
                    commit(to: target)
                    isCommitted = false
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { dragOffset = 0 }
                }
            }
    }

    private func commit(to target: PublicSchema.AccountScope) {
        isCommitted = true
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            session.scope = target
            dragOffset = 0
        }
    }

    /// How far the card actually moves for a finger that has moved `raw`.
    /// Superlinear, so the start of a drag is heavy and the end is not; at
    /// the ends of the carousel the exponent doubles and the card barely
    /// leaves its place at all.
    private func resisted(_ raw: CGFloat) -> CGFloat {
        let isAtEnd = neighbour(towards: raw) == nil
        let normalized = min(abs(raw) / step, 1)
        let distance = step * pow(normalized, isAtEnd ? 3.2 : 1.6)
        return raw < 0 ? -distance : distance
    }

    /// The card in the direction the finger is going — negative is leftward,
    /// which reveals the *next* scope. `nil` at either end.
    private func neighbour(towards direction: CGFloat) -> PublicSchema.AccountScope? {
        let next = direction < 0 ? index + 1 : index - 1
        guard scopes.indices.contains(next) else { return nil }
        return scopes[next]
    }
}

extension ScopeBannerView where Accessory == EmptyView, Filters == EmptyView {
    init(title: String, session: SessionStore, onOpenProfile: @escaping () -> Void) {
        self.init(
            title: title, session: session, onOpenProfile: onOpenProfile,
            accessory: { EmptyView() }, filters: { EmptyView() }
        )
    }
}

extension ScopeBannerView where Filters == EmptyView {
    init(
        title: String,
        session: SessionStore,
        onOpenProfile: @escaping () -> Void,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.init(
            title: title, session: session, onOpenProfile: onOpenProfile,
            accessory: accessory, filters: { EmptyView() }
        )
    }
}

/// The "you are not looking at everything" flag beside a screen title.
/// Never shown for Total — see `badgeTitle`.
struct ScopeBadge: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.4)
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.22), in: Capsule())
    }
}
