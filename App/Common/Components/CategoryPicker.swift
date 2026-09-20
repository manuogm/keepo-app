import KeepoCore
import SwiftUI

/// One category, as a tile you can pick — the row on the transaction form
/// and the full sheet behind it are both made of these, which is the point:
/// tapping "Groceries" has to look like the same act in both places.
///
/// **Unselected has no fill at all.** A tile that is merely on offer is an
/// icon and a word on the card's own surface; the one in force floods with
/// the category's colour. Every earlier attempt separated the two by
/// *degree* — a light wash against a lighter one — and degree is exactly
/// what stops working when the category's own colour is grey, which
/// "Other" is, and which every unclassified transaction lands in.
///
/// **The tile animates nothing on its own.** It renders two inputs —
/// chosen or not, whole or compacted — and the row that owns it drives
/// every change through an explicit `withAnimation`, because the swap it
/// performs is a sequence (compact, travel, expand) and a view that
/// animated its own state would run its own leg of that sequence on its
/// own clock.
struct CategoryChoiceTile: View {
    let category: PublicSchema.CategoriesSelect
    let isSelected: Bool
    /// Collapsed to a bare ball of the category's colour: no icon, no
    /// name, nothing but the shape that is about to travel. The tile keeps
    /// its full frame while compacted — the ball is what is *drawn*, not
    /// what is laid out — so the row does not resize under the animation.
    var isCompact = false
    /// Bigger in the sheet than on the form's row — the sheet is where
    /// somebody is hunting for a category they do not use often, and the
    /// icon is what they are scanning.
    var diameter: CGFloat = AppTheme.Size.touchTarget
    let action: () -> Void

    private var tint: Color { Color(hex: category.color) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: AppTheme.Spacing.s) {
                // `color: .clear` once the fill has somewhere to be: the
                // disc's own colour is painted by `fill` below, which at
                // rest is exactly the size and place of this disc. If the
                // disc painted itself too, the colour would leave a seam
                // behind as it grew out of it.
                CategoryIconView(
                    icon: category.icon,
                    color: isSelected ? .clear : tint,
                    diameter: diameter
                )

                // `captionEmphasis`, not `caption`: the name is the only
                // text on the tile and it is what the row is read by — at
                // regular weight it sat under its own icon like a
                // footnote. `textSecondary` while unchosen, matching the
                // plus tile beside it; `textOnAccent` once the tile is
                // flooded, which is contrast rather than hierarchy.
                Text(category.name)
                    .font(AppTheme.Typography.captionEmphasis)
                    .foregroundStyle(isSelected ? AppTheme.Palette.textOnAccent : AppTheme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // The contents go, the shape stays: a ball with a name under
            // it is not a ball.
            .opacity(isCompact ? 0 : 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppTheme.Spacing.m)
            .padding(.horizontal, AppTheme.Spacing.xs)
            .background { fill }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableCard)
        // **On the tile, not on the row** — so a category picked out of
        // the sheet ticks exactly like one picked off the row, and there
        // is one place that decides what choosing a category feels like.
        //
        // The condition is load-bearing: every selection flips *two*
        // tiles (one out, one in), so a bare trigger would fire twice at
        // once for one tap. Only the arrival plays.
        .sensoryFeedback(AppTheme.Feedback.selection, trigger: isSelected) { _, isNowSelected in isNowSelected }
    }

    /// **The tile's colour, as one circle at three sizes.**
    ///
    /// A ball while compacted, the icon disc at rest, and the whole tile
    /// once chosen — always the same circle, centred on the icon, masked
    /// inside the tile's rounded rect. Animating a radius is what makes
    /// the colour arrive and leave as a *shape*: it never cross-fades, in
    /// either direction, which is what made every earlier version of this
    /// look like four tiles bleeding into each other.
    ///
    /// At rest and unchosen the circle is exactly the disc, with the disc
    /// drawn over it — so it is invisible, and the growth out of it has
    /// nowhere to start from but the icon.
    private var fill: some View {
        GeometryReader { proxy in
            let centre = CGPoint(x: proxy.size.width / 2, y: AppTheme.Spacing.m + diameter / 2)
            let radius = radius(in: proxy.size, from: centre)
            RoundedRectangle(cornerRadius: AppTheme.Radius.card)
                .fill(tint)
                .mask(alignment: .topLeading) {
                    Circle()
                        .frame(width: radius * 2, height: radius * 2)
                        .offset(x: centre.x - radius, y: centre.y - radius)
                }
        }
    }

    private func radius(in size: CGSize, from centre: CGPoint) -> CGFloat {
        if isCompact { return Self.ballDiameter / 2 }
        guard isSelected else { return diameter / 2 }
        return Self.coveringRadius(from: centre, in: size)
    }

    /// Far enough from the disc's centre to swallow the tile's furthest
    /// corner — measured rather than guessed, because the disc sits near
    /// the top and the corner that wins is always a bottom one.
    private static func coveringRadius(from centre: CGPoint, in size: CGSize) -> CGFloat {
        let corners = [
            CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0),
            CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)
        ]
        return corners.map { hypot($0.x - centre.x, $0.y - centre.y) }.max() ?? size.height
    }

    /// Small enough to read as "a ball", not as "a smaller tile" — half
    /// the icon disc it collapses into.
    private static let ballDiameter = AppTheme.Size.glyph
}

/// How a transaction gets its category: the three the user reaches for
/// most, and an outlined plus for everything else.
///
/// It replaces a `Menu` over every category they own — flat, alphabetical
/// and icon-less, because a menu cannot draw a coloured disc. That made
/// the common case (the same handful of categories, over and over) cost a
/// scroll through a list where every row looked identical. The three are
/// ranked by what this account is actually used for
/// (`LocalCategoryRanking`), so the usual answer is one tap.
///
/// **One row, equal widths, names truncated.** Tiles that each sized
/// themselves to their own label made a ragged block that moved every time
/// the suggestions changed; a fixed quarter each keeps the row still.
struct CategorySuggestionRow: View {
    @Binding var selection: UUID?
    /// Up to three, most-used first, already narrowed to the kind on
    /// screen by whoever built them.
    let suggestions: [PublicSchema.CategoriesSelect]
    /// Every category valid for the current kind — what the plus opens.
    let categories: [PublicSchema.CategoriesSelect]

    @State private var isPickingCategory = false
    /// **The row keeps its own seating plan**, rather than re-deriving the
    /// order from the ranking on every selection. It has to, because the
    /// rule is a *swap*: the chosen tile takes the first slot and the tile
    /// that was there takes the slot the chosen one just left. That is a
    /// statement about where the tiles currently are, which the ranking
    /// does not know.
    @State private var arrangement: [UUID] = []
    /// The two tiles currently collapsed to balls — the pair mid-swap.
    @State private var compacted: Set<UUID> = []
    /// The ball travelling **over** the row: the one leaving the first
    /// slot. Its partner goes under, so the two are never ambiguous about
    /// which is arriving and which is being displaced.
    @State private var lifted: UUID?
    /// Shuts the row while a swap plays. A second tap mid-sequence would
    /// interleave two timelines over the same two `@State` values and
    /// leave a tile compacted with nowhere to go.
    @State private var isSwapping = false

    /// Three, plus the plus: four across one row at the widths this form
    /// is drawn at, and a fourth guess is not a guess any more.
    private static let slots = 3

    private var tiles: [PublicSchema.CategoriesSelect] {
        arrangement.compactMap { id in categories.first { $0.id == id } }
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.s) {
            ForEach(tiles, id: \.id) { category in
                CategoryChoiceTile(
                    category: category,
                    isSelected: category.id == selection,
                    isCompact: compacted.contains(category.id)
                ) {
                    select(category)
                }
                // Three layers, which is the whole readability of the
                // swap: the displaced ball rides over everything, the
                // arriving one slips under everything, and the tile that
                // is not moving sits between them.
                .zIndex(zIndex(for: category))
            }
            plusTile
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $isPickingCategory) {
            CategoryPickerSheet(selection: $selection, categories: categories)
        }
        .onAppear { reseat() }
        .onChange(of: suggestions.map(\.id)) { _, _ in reseat() }
        // A category chosen in the sheet, or set for us by the form when
        // the kind changes, has no swap to play: it simply takes the
        // front. `isSwapping` keeps this off the row's own path, which is
        // already moving the same tiles a step at a time.
        .onChange(of: selection) { _, _ in
            guard !isSwapping else { return }
            bringSelectionForward()
        }
    }

    private func zIndex(for category: PublicSchema.CategoriesSelect) -> Double {
        if category.id == lifted { return 2 }
        return category.id == selection ? 0 : 1
    }

    /// **Compact, swap, expand** — three phases, run from here rather than
    /// declared on the tiles, because each has to wait for the one before
    /// it. Both tiles collapse to balls where they stand; the balls trade
    /// places, one over the row and one under it; both open again once
    /// they have arrived.
    ///
    /// The waits are a fraction of each animation's nominal duration
    /// rather than the whole of it: `snappy` is a spring, and a spring is
    /// visually home well before its ramp ends — waiting it out in full
    /// put a visible stall between every phase.
    private func select(_ category: PublicSchema.CategoriesSelect) {
        guard !isSwapping else { return }
        guard let index = arrangement.firstIndex(of: category.id), index != 0 else {
            selection = category.id
            return
        }
        let displaced = arrangement[0]
        isSwapping = true
        selection = category.id
        Task { @MainActor in
            withAnimation(AppTheme.Motion.quick) { compacted = [category.id, displaced] }
            try? await Task.sleep(for: .seconds(AppTheme.Motion.quickDuration * Self.settled))
            lifted = displaced
            withAnimation(AppTheme.Motion.standard) { arrangement.swapAt(0, index) }
            try? await Task.sleep(for: .seconds(AppTheme.Motion.standardDuration * Self.settled))
            withAnimation(AppTheme.Motion.quick) { compacted = [] }
            try? await Task.sleep(for: .seconds(AppTheme.Motion.quickDuration))
            lifted = nil
            isSwapping = false
        }
    }

    /// How much of a spring's nominal duration to wait before starting the
    /// next phase. Measured off 0.05s frame captures rather than picked:
    /// the shape is where it is going about two thirds of the way through.
    private static let settled = 0.7

    /// Seats the row from the ranking, then brings the current selection
    /// to the front. Run on appear and whenever the suggestions change — a
    /// new account, or a switch between expense and income, is a new
    /// ranking, and the old seating plan means nothing against it.
    private func reseat() {
        arrangement = suggestions.prefix(Self.slots).map(\.id)
        bringSelectionForward()
    }

    /// The swap, without the animation — for the selections that arrive
    /// from somewhere other than a tap on this row. A category picked out
    /// of the sheet came from no slot at all, so there is nowhere to send
    /// the incumbent: it leaves the row, and the tiles that did not move
    /// stay where they were.
    private func bringSelectionForward() {
        guard let selection else { return }
        if let index = arrangement.firstIndex(of: selection) {
            guard index != 0 else { return }
            arrangement.swapAt(0, index)
        } else if arrangement.isEmpty {
            arrangement = [selection]
        } else {
            arrangement[0] = selection
        }
    }

    /// The way to every other category, built to the same measurements as
    /// the three beside it — same disc size, same label slot — so the row
    /// reads as four of one thing rather than three and a stray glyph.
    ///
    /// **Outlined, not filled.** A solid disc would make it look like a
    /// fourth suggestion; the ring is the same quiet treatment the amount
    /// field's calculator button already uses for "a control, not an
    /// answer".
    private var plusTile: some View {
        Button {
            isPickingCategory = true
        } label: {
            VStack(spacing: AppTheme.Spacing.s) {
                Image(systemName: "plus")
                    .font(AppTheme.Typography.labelEmphasis)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .frame(width: AppTheme.Size.touchTarget, height: AppTheme.Size.touchTarget)
                    .overlay(Circle().strokeBorder(AppTheme.Palette.textSecondary, lineWidth: 1))
                Text("More")
                    .font(AppTheme.Typography.captionEmphasis)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppTheme.Spacing.m)
            .padding(.horizontal, AppTheme.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableCard)
        .accessibilityLabel("All categories")
    }
}

/// Every category for the kind on screen, as the same tiles the form's row
/// is made of — icon, colour, name — rather than as menu text.
///
/// One tap selects, closes, and lands the category in the row's first
/// slot, for the same reason the date picker dismisses on a tap: the tap
/// IS the answer, and a Done button behind it asks the user to confirm a
/// choice they have already made.
struct CategoryPickerSheet: View {
    @Binding var selection: UUID?
    let categories: [PublicSchema.CategoriesSelect]

    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: AppTheme.Spacing.s), count: 3)

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.Palette.bgCanvas.ignoresSafeArea()
                ScrollView {
                    LazyVGrid(columns: columns, spacing: AppTheme.Spacing.s) {
                        ForEach(categories, id: \.id) { category in
                            CategoryChoiceTile(
                                category: category,
                                isSelected: category.id == selection,
                                diameter: AppTheme.Size.avatar
                            ) {
                                selection = category.id
                                dismiss()
                            }
                        }
                    }
                    .padding(AppTheme.Spacing.l)
                }
            }
            .navigationTitle("Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
