import KeepoCore
import SwiftUI

/// The part of a lesson that is a list rather than a sentence.
///
/// Two lessons make a claim — "three scopes", "two things put something in
/// the inbox" — that is only really made by showing them, so their
/// `message` is a lead-in and this is the rest of it. Without this, both
/// read as a sentence that stops at a colon.
///
/// **Shared by the coach mark and the tour**, which is the whole reason it
/// is a view of its own: "Show Me Around" is the page somebody reads when
/// they dismissed a card too early, and a page that dropped the half of the
/// lesson that mattered would be the one surface that cannot be checked
/// against the other.
struct FTUXLessonDetail: View {
    let lesson: FTUXLesson

    var body: some View {
        switch lesson.id {
        case FTUXLessons.scope.id: scopes
        case FTUXLessons.needsReview.id: inbox
        default: EmptyView()
        }
    }

    /// The three scopes, each against its own colour — the same colour the
    /// banner will be wearing a moment after the user swipes to it, which
    /// is the entire point of showing them as swatches rather than naming
    /// them in a sentence.
    private var scopes: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            ForEach(PublicSchema.AccountScope.carousel, id: \.self) { scope in
                HStack(spacing: AppTheme.Spacing.m) {
                    Circle()
                        .fill(scope.tint)
                        .frame(width: AppTheme.Size.glyphSmall, height: AppTheme.Size.glyphSmall)

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        Text(scope.title)
                            .font(AppTheme.Typography.labelEmphasis)
                            .foregroundStyle(AppTheme.Palette.textPrimary)
                        Text(scope.caption)
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// What actually puts something in the inbox, which is the whole point
    /// of the lesson: it is not a list of everything, it is the two things
    /// that need *you*.
    ///
    /// Both glyphs in the same secondary ink, outlined rather than filled.
    /// A red filled triangle was the only saturated thing on the card and
    /// read as an error happening now, when the line is describing a kind
    /// of item the inbox can hold.
    private var inbox: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            inboxRow(glyph: "icon-robot", text: "Review an automatically captured purchase")
            inboxRow(glyph: "exclamationmark.triangle", text: "Solve a synchronization issue")
        }
    }

    private func inboxRow(glyph: String, text: String) -> some View {
        HStack(spacing: AppTheme.Spacing.m) {
            ScopeGlyph(name: glyph, size: AppTheme.Size.glyphSmall)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .frame(width: AppTheme.Size.glyphSmall)
            Text(text)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
