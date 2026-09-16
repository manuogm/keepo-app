import KeepoCore
import SwiftUI

/// The one coach mark in Keepo: a dimmed screen with a hole cut in it,
/// around the scope banner.
///
/// **Only one thing in the app earns an interruption**, and this is it. The
/// scope swipe is a horizontal gesture on a header with no affordance,
/// which silently changes what every number on screen means — invisible and
/// important at the same time. Everything else Keepo could teach is taught
/// just-in-time by a TipKit tip, on the screen it is about, or read on
/// demand from "Show me around".
///
/// **Hand-rolled rather than TipKit, for one concrete reason**: a TipKit
/// popover cannot dim the background and cut a hole in it, and the whole
/// point here is to show *the banner* while everything else recedes. That
/// is the only part of this layer TipKit could not do better.
struct SpotlightOverlay: View {
    /// Where to cut. In the overlay's own coordinate space, resolved by the
    /// caller from an `.ftuxAnchor()` further down the hierarchy.
    let cutout: CGRect
    let lesson: FTUXLesson
    let onDismiss: () -> Void

    /// Enough that the cut-out reads as a highlight around the banner
    /// rather than as a crop of it.
    private static let padding: CGFloat = 8

    var body: some View {
        ZStack(alignment: .topLeading) {
            scrim
            bubble
        }
        .ignoresSafeArea()
        .transition(.opacity)
        // One gesture, anywhere: there is nothing to do here but understand
        // it, so anything that looks like "go on then" has to work.
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(lesson.title). \(lesson.message)")
        .accessibilityHint("Tap anywhere to dismiss")
        .accessibilityAddTraits(.isModal)
    }

    /// Even-odd fill rather than `.blendMode(.destinationOut)`: the hole has
    /// to be a hole in a *shape*, so the tap target and the drawing agree,
    /// and a destination-out composite would need its own compositing group
    /// to avoid punching through the app underneath it as well.
    private var scrim: some View {
        GeometryReader { proxy in
            Path { path in
                path.addRect(CGRect(origin: .zero, size: proxy.size))
                path.addRoundedRect(
                    in: hole,
                    cornerSize: CGSize(width: AppTheme.Radius.surface, height: AppTheme.Radius.surface)
                )
            }
            .fill(Color.black.opacity(AppTheme.Opacity.scrim), style: FillStyle(eoFill: true))
        }
    }

    private var hole: CGRect {
        cutout.insetBy(dx: -Self.padding, dy: -Self.padding)
    }

    /// Below the banner, because the banner is at the top of every screen —
    /// placed above it the bubble would be off-screen, and placed centrally
    /// it would cover the thing it is pointing at.
    private var bubble: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            Label(lesson.title, systemImage: lesson.symbol)
                .font(AppTheme.Typography.bodyEmphasis)
                .foregroundStyle(AppTheme.Palette.textPrimary)
            Text(lesson.message)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Tap anywhere to continue")
                .font(AppTheme.Typography.nano)
                .foregroundStyle(AppTheme.Palette.textSecondary)
        }
        .padding(AppTheme.Spacing.l)
        .frame(maxWidth: AppTheme.Size.proseWidth, alignment: .leading)
        .background(AppTheme.Palette.bgSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card))
        .elevation(.floating)
        .padding(.horizontal, AppTheme.Spacing.l)
        .offset(y: hole.maxY + AppTheme.Spacing.l)
    }
}

// MARK: - Anchoring

/// Where the spotlight should cut, published by the view it is about.
///
/// An `Anchor<CGRect>` rather than a resolved frame: the banner does not
/// know what coordinate space the overlay will be resolved in, and an
/// anchor is the one thing SwiftUI can translate correctly across that gap.
struct FTUXAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        // First wins. Four tabs each render a scope banner, and a tab that
        // is merely *prepared* rather than visible would otherwise be able
        // to move the hole.
        value = value ?? nextValue()
    }
}

extension View {
    /// Marks this view as the thing the spotlight points at.
    func ftuxAnchor() -> some View {
        anchorPreference(key: FTUXAnchorKey.self, value: .bounds) { $0 }
    }
}

/// Resolves the anchor and draws the overlay over the whole app.
///
/// **`isVisible` is a plain argument, not read from the coordinator inside
/// the closure**, and that is load-bearing. `overlayPreferenceValue`'s
/// builder runs in its own update pass, so an `@Observable` property read
/// only in there does not reliably register as a dependency of the view's
/// body — the flag flipped and nothing redrew, which showed up as "Show me
/// around" replaying the spotlight to a screen that never changed. Read at
/// the call site, in `body`, the dependency is ordinary.
private struct SpotlightModifier: ViewModifier {
    let isVisible: Bool
    let lesson: FTUXLesson
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(FTUXAnchorKey.self) { anchor in
                GeometryReader { proxy in
                    if isVisible, let anchor {
                        SpotlightOverlay(cutout: proxy[anchor], lesson: lesson, onDismiss: onDismiss)
                    }
                }
                .ignoresSafeArea()
            }
            .animation(AppTheme.Motion.standard, value: isVisible)
    }
}

extension View {
    func spotlight(
        isVisible: Bool, lesson: FTUXLesson, onDismiss: @escaping () -> Void
    ) -> some View {
        modifier(SpotlightModifier(isVisible: isVisible, lesson: lesson, onDismiss: onDismiss))
    }
}
