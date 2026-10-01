import KeepoCore
import SwiftUI

/// One tag, wherever it appears — the transaction form's row, the tag
/// sheet, the All Tags list, the household report.
///
/// Name only, and no hue of its own. A tag has no icon and no per-tag colour
/// on purpose: categories already own the colourful layer, and giving tags
/// one too would put two competing colour systems on the same screen with
/// nothing telling the user which kind of thing a given chip is.
struct TagChip: View {
    let name: String
    /// Filled means "this tag is on this transaction"; hollow is a choice not
    /// yet made — a suggestion, an unpicked tag in the sheet, a tag at rest
    /// in the All Tags list.
    var isSelected = true

    var body: some View {
        Text(name)
            .font(AppTheme.Typography.label)
            .lineLimit(1)
            .tagPill(isSelected: isSelected)
    }
}

extension View {
    /// The pill every tag wears, shared by `TagChip`, the All Tags list's
    /// editable pill and `NewTagField` once it is being typed in — three
    /// views that have to read as the same object.
    ///
    /// **Selected is filled with ink; unselected is an ink outline.** The
    /// label on the fill is `inkOnPrimaryFill`, not `textOnAccent`: the ink
    /// is near-white in dark mode, and white on it would vanish.
    func tagPill(isSelected: Bool) -> some View {
        modifier(TagSlotStyle(look: isSelected ? .selected : .unselected))
    }
}

/// The three looks a tag-shaped thing can wear. One modifier, switching only
/// colours and the background — **never the content's structure**. A
/// branch around the content would rebuild a text field inside it the
/// moment its focus changed the look, and drop the focus that changed it.
private struct TagSlotStyle: ViewModifier {
    enum Look {
        case selected, unselected, dashed
    }

    let look: Look

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .foregroundStyle(foreground)
            .padding(.horizontal, AppTheme.Spacing.m)
            .padding(.vertical, AppTheme.Spacing.s)
            .background {
                switch look {
                case .selected:
                    Capsule().fill(AppTheme.Palette.textPrimary)
                case .unselected:
                    Capsule().strokeBorder(AppTheme.Palette.textPrimary, lineWidth: 1)
                case .dashed:
                    Capsule()
                        .strokeBorder(AppTheme.Palette.fillStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .contentShape(Capsule())
    }

    private var foreground: Color {
        switch look {
        case .selected: AppTheme.Palette.inkOnPrimaryFill(colorScheme)
        case .unselected: AppTheme.Palette.textPrimary
        case .dashed: AppTheme.Palette.fillStrong
        }
    }
}

/// The dashed way into the tag sheet from the transaction form's row. A
/// dashed border reads as "a slot, not a thing" — it is the one pill in the
/// row that is not itself a tag.
///
/// "Add Tags" until the row is showing suggestions, then "All Tags": the
/// tags most likely wanted are already there, so what the button opens is
/// the rest of them.
struct AddTagButton: View {
    var title = "Add Tags"

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "plus")
                .font(AppTheme.Typography.microEmphasis)
            Text(title)
                .font(AppTheme.Typography.label)
        }
        .modifier(TagSlotStyle(look: .dashed))
    }
}

/// A tag that does not exist yet: a dashed slot reading "New Tag" until it
/// is tapped, then the pill being named. The All Tags list and the tag sheet
/// both create tags this way, so it is one view.
///
/// The moment the caret lands, it **fills** — from then on the user is
/// typing a tag, and an outline that only became a tag on return made the
/// thing they were naming look like it wasn't there yet. The plus and the
/// placeholder go with the outline: both say "start something", which the
/// caret already says.
///
/// Generic over the caller's focus enum, because each caller tracks focus
/// across more fields than this one.
struct NewTagField<Field: Hashable>: View {
    @Binding var text: String
    let focus: FocusState<Field?>.Binding
    let field: Field
    let onCommit: () -> Void

    private var isEditing: Bool { focus.wrappedValue == field }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            if !isEditing {
                Image(systemName: "plus")
                    .font(AppTheme.Typography.microEmphasis)
            }
            TextField(isEditing ? "" : "New Tag", text: $text)
                .font(AppTheme.Typography.label)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .focused(focus, equals: field)
                .tint(AppTheme.Palette.inkOnPrimaryFill(colorScheme))
                .fixedSize()
                // A minimum width so an empty field is still a target;
                // `fixedSize` alone would collapse it to the caret.
                .frame(minWidth: AppTheme.Size.illustration, alignment: .leading)
                .accessibilityLabel("New tag name")
                .onSubmit(onCommit)
                .onChange(of: focus.wrappedValue) { previous, _ in
                    if previous == field { onCommit() }
                }
        }
        .modifier(TagSlotStyle(look: isEditing ? .selected : .dashed))
        .animation(AppTheme.Motion.standard, value: isEditing)
    }
}
