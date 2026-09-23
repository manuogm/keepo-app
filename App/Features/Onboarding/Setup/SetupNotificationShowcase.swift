import KeepoCore
import SwiftUI
import UserNotifications

/// What a capture actually looks like — four honest stills, swipeable, each
/// drawn the way iOS draws a Keepo notification once it has been pressed.
///
/// **One card was a half-truth.** The screen asks for permission to send
/// notifications and used to show a single happy-path capture: everything
/// resolved, nothing to do. That is the least interesting of the four and
/// the one that least needs a notification. The ones that earn the
/// permission are the others — a category Keepo had to guess, a card it has
/// never seen, and a purchase that looks like it already happened — and
/// each of those turns into a list of actions that settles it without
/// opening the app. A user who has seen those four knows what they are
/// agreeing to.
///
/// **Drawn as the real thing, not as a card about it.** The stills used to be
/// white app cards with the copy in them, which read as Keepo *describing* a
/// notification. A user recognises the banner itself — icon, bold line, age
/// at the far edge, one frosted platter — so that is what is drawn, measured
/// off a device screenshot, and every dimension landed on an existing token.
/// The long-press actions sit under it as iOS lays them out: a second, narrower
/// platter of rows, not chips.
///
/// Nothing here is hand-written: the text comes from
/// `CaptureNotificationCopy.appliedLocally` and the actions from
/// `CaptureQuickActions.build`, both fed the resolutions in
/// `CaptureNotificationCopy.showcase`. A card cannot promise a shape
/// production does not send.
struct NotificationShowcase: View {
    let currency: String?

    @State private var visible: Int?

    private var samples: [CaptureLocalWrite.Resolution] {
        CaptureNotificationCopy.showcase(currency: currency)
    }

    /// The banner's trailing label, per still. Staggered rather than all
    /// "now": four notifications that arrived in the same instant is not a
    /// thing a lock screen ever shows, and the sameness is what gives a
    /// mock-up away.
    private static let ages = ["now", "2m ago", "15m ago", "1h ago"]

    var body: some View {
        VStack(spacing: AppTheme.Spacing.m) {
            ScrollView(.horizontal) {
                // Not lazy: there are four, and a lazy stack sizes its
                // cross axis from an *estimate* of children it has not
                // built — which left a band of empty wallpaper under every
                // card, taller than any of them.
                HStack(alignment: .top, spacing: AppTheme.Spacing.m) {
                    ForEach(Array(samples.enumerated()), id: \.offset) { index, resolution in
                        NotificationStill(resolution: resolution, age: Self.ages[index % Self.ages.count])
                            // Nineteen twentieths: as near a real banner's
                            // width as leaves the next card's edge showing. A
                            // carousel of full-width cards is a carousel
                            // nobody scrolls, because nothing on screen says
                            // there is more than one.
                            .containerRelativeFrame(.horizontal, count: 20, span: 19, spacing: 0)
                            .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $visible)
            // The screen-edge inset, and the only one. The notification
            // sits `l` in from the edge of the glass exactly as a real one
            // sits in from the edge of the phone.
            .contentMargins(.horizontal, AppTheme.Spacing.l, for: .scrollContent)
            .padding(.vertical, AppTheme.Spacing.l)
            // **The glass needs something behind it.** A material is a blur
            // of whatever it covers; over the flat grey canvas that is
            // nothing, and the platter reads as one more grey card.
            //
            // **Edge to edge, not a rounded panel inside the margins.** The
            // panel version put two insets between the screen and the
            // notification — the step's own margin, then the panel's — so the
            // banner sat visibly further in than a real one does and read as
            // a picture of a phone rather than the phone. Bled to both edges,
            // the wallpaper is the screen and the banner has one margin, the
            // real one.
            .background { NotificationWallpaper() }
            .padding(.horizontal, -AppTheme.Spacing.l)

            dots
        }
    }

    /// The count, not decoration: with the tenth-of-a-card peek the reader
    /// knows there is a next one, and the dots are what say how many are
    /// left.
    private var dots: some View {
        HStack(spacing: AppTheme.Spacing.s) {
            ForEach(samples.indices, id: \.self) { index in
                Circle()
                    .fill(
                        index == (visible ?? 0)
                            ? AppTheme.Palette.textSecondary
                            : AppTheme.Palette.textSecondary.opacity(AppTheme.Opacity.fillStrong)
                    )
                    .frame(width: AppTheme.Size.dot, height: AppTheme.Size.dot)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

/// One notification, as iOS draws it after a long press: the banner, then its
/// actions.
///
/// **The banner** is the collapsed notification exactly — icon, bold title
/// with its age at the trailing edge, the body under it, all inside one
/// frosted platter. The title may wrap where iOS would let it run on one
/// line: these stills are slightly narrower than a real banner, and cutting
/// "Logged successfully" to "Logged succ…" would hide the one phrase each
/// still exists to show.
///
/// **The actions** are the menu iOS puts under a pressed notification: their
/// own platter, narrower than the banner and hung from its leading edge, one
/// full-width row per action. They were inline chips for a while, which kept
/// the card short and was a shape no iPhone ever draws.
private struct NotificationStill: View {
    let resolution: CaptureLocalWrite.Resolution
    let age: String

    private var copy: CaptureNotificationCopy.Content {
        CaptureNotificationCopy.appliedLocally(resolution)
    }

    private var actions: [UNNotificationAction] {
        CaptureQuickActions.build(for: resolution).actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            banner
            // The "both unknown" branch genuinely has no actions, and an
            // empty menu would be a promise the real notification does not
            // keep.
            if !actions.isEmpty {
                actionMenu
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Example notification. \(copy.title). \(copy.body). "
                + "Actions: \(actions.map(\.title).joined(separator: ", "))"
        )
    }

    private var banner: some View {
        HStack(spacing: AppTheme.Spacing.m) {
            NotificationAppIcon()

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.s) {
                    Text(copy.title)
                        .font(AppTheme.Typography.labelEmphasis)
                        .foregroundStyle(AppTheme.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text(age)
                        .font(AppTheme.Typography.label)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                        .fixedSize()
                }
                Text(copy.body)
                    .font(AppTheme.Typography.label)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.l)
        .padding(.vertical, AppTheme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notificationPlatter()
    }

    private var actionMenu: some View {
        VStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                if index > 0 { Divider() }
                Text(action.title)
                    .font(AppTheme.Typography.body)
                    // `.destructive` is the only option that takes a colour,
                    // exactly as it does on the real thing.
                    .foregroundStyle(
                        action.options.contains(.destructive)
                            ? AppTheme.Palette.statusNegative
                            : AppTheme.Palette.textPrimary
                    )
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppTheme.Spacing.l)
                    .padding(.vertical, AppTheme.Spacing.m)
            }
        }
        .notificationPlatter()
        // Two thirds of the carousel's width: the proportion iOS gives the
        // menu under a pressed notification, and what keeps the two platters
        // reading as a notification and *its* menu rather than two cards.
        .containerRelativeFrame(.horizontal, count: 3, span: 2, spacing: 0, alignment: .leading)
    }
}

/// Keepo's own app icon at the size a notification draws it.
///
/// The asset is the app icon downscaled to exactly this size
/// (`NotificationIcon.imageset`) rather than the 1024pt original resized at
/// runtime: an asset catalogue rasterises from the source's intrinsic size,
/// and a 1024 bitmap per scale for a 32pt image is the Assets.car bloat
/// `lessons-learned.md` already records once.
private struct NotificationAppIcon: View {
    /// Apple's app-icon corner as a fraction of the icon's side. A property of
    /// the icon's own shape, so it scales with it rather than being a spacing
    /// value from the brand scale.
    private static let cornerRatio: CGFloat = 0.225

    var body: some View {
        Image("NotificationIcon")
            .resizable()
            .scaledToFill()
            .frame(width: AppTheme.Size.icon, height: AppTheme.Size.icon)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Size.icon * Self.cornerRatio, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A lock screen's worth of colour for the platters to frost: mango into the
/// private scope's indigo, both brand tokens, so the showcase stays on-palette
/// while still giving the material something to blur.
///
/// A mesh rather than blurred shapes: it is resolution-independent and takes
/// its geometry as proportions of whatever size it is given, so there is no
/// blob diameter or blur radius to pick outside the token scale.
private struct NotificationWallpaper: View {
    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.45, 0.55], [1, 0.4],
                [0, 1], [0.5, 1], [1, 1]
            ],
            colors: [
                AppTheme.Palette.scopeTotal, AppTheme.Palette.scopeTotal, AppTheme.Palette.scopeTotal,
                AppTheme.Palette.scopeTotal, AppTheme.Palette.scopeTotal, AppTheme.Palette.scopePrivate,
                AppTheme.Palette.scopePrivate, AppTheme.Palette.scopePrivate, AppTheme.Palette.scopePrivate
            ],
            // Perceptual, not sRGB: mango and indigo sit across the wheel
            // from each other, and an sRGB blend between them passes through
            // a muddy brown the eye reads as a smudge rather than as light.
            colorSpace: .perceptual
        )
    }
}

private extension View {
    /// The frosted panel every part of a notification sits on. The system
    /// material rather than a palette colour: it is the platter's actual
    /// fabric, and it follows light and dark on its own.
    func notificationPlatter() -> some View {
        background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.surface, style: .continuous)
        )
    }
}
