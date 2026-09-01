import SwiftUI

/// A template icon from `Assets.xcassets/Icons`, sized to a square box and
/// tinted by the caller's `foregroundStyle` (the assets are template-rendered,
/// so the tint propagates in).
///
/// Every custom-asset glyph in the app renders through here: an `Image` from
/// the catalogue needs `.resizable().scaledToFit()` and an explicit frame to
/// size at all — `.font(...)` only moves SF Symbols — and that trio was
/// getting copied to every call site. One place, not a dozen.
struct KeepoIcon: View {
    let name: String
    /// Defaults to the badge/compact-row size; callers sitting next to small
    /// text or inside a fixed control pass their own.
    var size: CGFloat = AppTheme.Size.glyph

    var body: some View {
        Image(name)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}
