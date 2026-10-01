import KeepoCore
import SwiftUI
import UIKit

/// The user's face, wherever it appears — the scope banner's tap target
/// into Profile, and Profile's own header. One view so the two can't drift
/// apart the day a real uploaded photo replaces the initial.
struct ProfileAvatarView: View {
    /// Preferred over `email` for the initial: a user who told the app their
    /// name should see that name's letter, not the first character of an
    /// address they may never have chosen. Nil until they have set one.
    var name: String?
    let email: String?
    /// The uploaded picture, when one has been loaded. The initial below is
    /// not a placeholder for a slow image — it is what the avatar *is* until
    /// the user sets a photo, and what it goes back to if they remove one.
    var image: UIImage?
    var size = AppTheme.Size.icon
    /// Drawn on a saturated gradient card (`onColor: true`) or on the app's
    /// own neutral surface. The face and its outline differ, so this is a
    /// flag rather than two views.
    var onColor = false
    /// What an avatar without a photo shows. The banner is always the user
    /// icon, whatever this says; other people's avatars keep the initial
    /// that tells them apart; the user's own Profile is an invitation to add
    /// a photo.
    var placeholder = Placeholder.initial

    enum Placeholder {
        case initial
        /// A plus in a dashed circle — the same "add one" mark the empty
        /// dashboard and its widget slot use.
        case addPhoto
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    // Fill, not fit: the source is already a centre-cropped
                    // square (`AvatarStore.downscaledJPEG`), so this only has
                    // to cover rounding, and `fit` would leave hairline gaps
                    // at the circle's edge.
                    .scaledToFill()
            } else {
                initialFace
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            // Only a photo needs an edge against the card. The user icon
            // already is a ring, and a second one around it reads as two.
            if onColor, image != nil {
                Circle().strokeBorder(AppTheme.Palette.textOnAccent.opacity(AppTheme.Opacity.muted), lineWidth: 1)
            }
        }
    }

    /// The user icon draws its own ring and needs no fill — the initial's
    /// tinted fill is what makes a letter read as an avatar.
    @ViewBuilder
    private var initialFace: some View {
        if onColor {
            KeepoIcon(name: "icon-user", size: size)
                .foregroundStyle(AppTheme.Palette.textOnAccent)
        } else if placeholder == .addPhoto {
            Image(systemName: "plus")
                .font(.system(size: size * 0.35, weight: .light))
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .frame(width: size, height: size)
                .overlay(
                    Circle().strokeBorder(
                        AppTheme.Palette.fillStrong,
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                    )
                )
        } else {
            ZStack {
                Circle().fill(AppTheme.Palette.textPrimary.opacity(AppTheme.Opacity.fill))
                Text(initial)
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(AppTheme.Palette.textPrimary)
            }
        }
    }

    /// The first letter of the name, falling back to the email, falling back
    /// to "?" — never a blank circle, which reads as a failed image load
    /// rather than as an account without a picture. `trimmingCharacters`
    /// because a name stored with leading space would otherwise render its
    /// space.
    private var initial: String {
        let source = [name, email]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return String((source ?? "?").prefix(1)).uppercased()
    }
}
