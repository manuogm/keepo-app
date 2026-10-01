import KeepoCore
import SwiftUI

/// The widget catalogue, as a panel **inside the dashboard's own view
/// hierarchy** rather than a `.sheet`.
///
/// That is not a styling choice: a `.sheet` cannot host this list's two jobs
/// at once. It has to scroll, and a widget has to come *out* of it onto the
/// dashboard underneath — which a sheet cannot show at all.
///
/// The drag out is a **system drag session** (`.onDrag`), not a SwiftUI
/// `DragGesture`, and that is the second load-bearing decision here. Every
/// gesture-based attempt failed the same way, measured in the simulator: a
/// `DragGesture` on a scrolling row — sequenced behind a long press, and
/// even attached with `.simultaneousGesture` — wins arbitration against the
/// enclosing `ScrollView` from the first touch down, and this list simply
/// refuses to move, stranding every widget below the fold. Removing that one
/// modifier restored scrolling instantly; nothing else did. A drag session
/// is what UIKit built for this shape of interaction (it is how the home
/// screen's own widget gallery works): the lift coexists with the scroll
/// pan, the preview is carried by the window rather than by this view, and
/// so the panel is free to get out of the way the moment the drag begins
/// without the widget going with it.
///
/// Every entry is the real widget view rendered against `DashboardData
/// .sample`, not a mock-up — as the tile on the dashboard, as the picture in
/// this list, and as the preview under the finger. A preview whose only job
/// is to promise what you're about to get has to be the thing itself.
struct DashboardCatalogView: View {
    let geometry: DashboardGeometry
    let maxHeight: CGFloat
    /// Which widgets are already on the dashboard. They move to their own
    /// shelf rather than sitting greyed among the ones you can still add —
    /// the rule is one of each, so a used widget is not an entry that
    /// happens to be disabled, it is an entry that has already been spent.
    var placed: Set<DashboardWidgetKind> = []
    /// Why a widget that **isn't** placed still can't be added — missing
    /// data, keyed by kind. Absent means it can.
    ///
    /// These entries stay **visible**, greyed, with the reason under them.
    /// Hiding them would answer "where is the FX widget?" with silence;
    /// showing it disabled answers it with "add a second currency".
    var unavailable: [DashboardWidgetKind: String] = [:]
    /// Tapping still adds the widget the quick way, at the first free slot.
    let onSelect: (DashboardWidgetKind) -> Void
    let onClose: () -> Void
    /// Which widget is being carried out of the list. Called as the drag
    /// session begins — and again, later, when the drop resolves the item,
    /// which is why it must stay a note of *what* rather than an action:
    /// see the comment on `onDrag` below.
    let onLift: (DashboardWidgetKind) -> Void

    /// Which shelf is showing. Opens on Keepo, the one whose entries you
    /// can act on — Used exists to get placed widgets out of the way.
    @State private var shelf: Shelf = .keepo
    /// How far the panel has been pulled down by its grabber. Not reset
    /// when the pull dismisses: the panel leaves from where the finger let
    /// go rather than snapping back up first.
    @State private var dragOffset: CGFloat = 0
    /// Which widget's explainer is open. The catalogue's ⓘ opens the **same**
    /// sheet the widget's own header does — one description of a widget,
    /// wherever you meet it.
    @State private var explaining: DashboardWidgetKind?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                shelfContents
                    .padding(.horizontal, inset)
                    .padding(.top, AppTheme.Spacing.l)
                    .padding(.bottom, AppTheme.Spacing.xl + KeepoTabBarMetrics.clearance)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxHeight: maxHeight)
        // The panel's *layout* stops at the bottom safe area — which is
        // where the floating tab bar now lives, so the last entry in the
        // list is reachable instead of sitting under it — while its
        // background alone paints on through to the screen edge, so the
        // panel still reads as anchored rather than hovering.
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28)
                .fill(AppTheme.Palette.bgCanvas)
                .elevation(.floating)
                .ignoresSafeArea(edges: .bottom)
        }
        // After the background, so the panel's surface travels with the
        // pull rather than staying behind as an empty card.
        .offset(y: dragOffset)
        .sheet(item: $explaining) { kind in
            WidgetGuideSheet(title: kind.title, guide: kind.guide)
        }
    }

    private var inset: CGFloat { AppTheme.Spacing.l }

    /// Dressed as a sheet, because it behaves like one: it slides up from
    /// the bottom and goes away on a pull down. The grabber, and the X at
    /// the leading edge as glass, are what every real sheet in the app
    /// shows — this panel was the one place the X sat trailing in a grey
    /// disc, and it read as a different kind of thing.
    ///
    /// The pull is on the grabber and title row only. The list below has to
    /// keep its scroll (see the type's header), and the shelf picker runs
    /// its own pan to slide between segments.
    private var header: some View {
        VStack(spacing: AppTheme.Spacing.m) {
            VStack(spacing: AppTheme.Spacing.s) {
                Capsule()
                    .fill(AppTheme.Palette.textTertiary)
                    .frame(width: AppTheme.Size.grabber.width, height: AppTheme.Size.grabber.height)
                    .accessibilityHidden(true)
                ZStack {
                    Text("Add Widget")
                        .font(AppTheme.Typography.rowTitle)
                    HStack {
                        closeButton
                        Spacer(minLength: 0)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(pullToDismiss)

            Picker("Show", selection: $shelf) {
                ForEach(Shelf.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .sensoryFeedback(AppTheme.Feedback.selection, trigger: shelf)
        }
        .padding(.horizontal, inset)
        .padding(.top, AppTheme.Spacing.s)
    }

    /// The toolbar X every sheet carries — a glyph on a glass circle — drawn
    /// by hand because a panel has no toolbar to put it in.
    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(AppTheme.Typography.bodyEmphasis)
                .foregroundStyle(AppTheme.Palette.textPrimary)
                .frame(width: AppTheme.Size.touchTarget, height: AppTheme.Size.touchTarget)
                .liquidGlass(in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }

    /// How far a pull has to travel to dismiss — or a flick has to be
    /// projected to travel, at twice this. Anything less springs back.
    private static let dismissDistance: CGFloat = 80

    /// Down only — an upward pull has nowhere to go.
    private var pullToDismiss: some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                if value.translation.height > Self.dismissDistance
                    || value.predictedEndTranslation.height > Self.dismissDistance * 2 {
                    onClose()
                } else {
                    withAnimation(AppTheme.Motion.standard) { dragOffset = 0 }
                }
            }
    }

    // MARK: - Shelves

    /// The two shelves a widget can be on, one at a time. A widget is on
    /// exactly one: "Keepo" is what you can add, "Used" is what is already
    /// out. A filter rather than stacked collapsible groups, so the panel
    /// opens on the list you came for instead of on a row of headers.
    enum Shelf: String, CaseIterable, Identifiable {
        case keepo
        case used

        var id: String { rawValue }

        var title: String {
            switch self {
            case .keepo: return "Keepo Widgets"
            case .used: return "Used Widgets"
            }
        }

        /// What an empty shelf says. Never a bare "nothing here" — an empty
        /// shelf is an achievement (everything is on the dashboard) or a
        /// pointer to the other one.
        var blankState: String {
            switch self {
            case .keepo: return "Every Keepo widget is on your dashboard."
            case .used: return "Nothing on your dashboard yet — add one from Keepo Widgets."
            }
        }
    }

    private func kinds(on shelf: Shelf) -> [DashboardWidgetKind] {
        switch shelf {
        case .keepo: return DashboardWidgetKind.allCases.filter { !placed.contains($0) }
        case .used: return DashboardWidgetKind.allCases.filter { placed.contains($0) }
        }
    }

    @ViewBuilder
    private var shelfContents: some View {
        let members = kinds(on: shelf)
        if members.isEmpty {
            Text(shelf.blankState)
                .font(AppTheme.Typography.label)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, AppTheme.Spacing.m)
        } else {
            LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                ForEach(members, id: \.self) { kind in
                    entry(kind, isPlaced: shelf == .used)
                }
            }
        }
    }

    // MARK: - Entries

    /// No size badge, and **no description line**. The preview underneath is
    /// rendered at the exact cell size the dashboard would give it, so the
    /// footprint is already on screen — a "2×1" beside it describes the
    /// grid's bookkeeping rather than anything the user needs to read. And a
    /// one-line summary under every title was six lines of prose stacked
    /// down the panel, saying a weaker version of what the widget's own ⓘ
    /// already says properly. The ⓘ moved here instead: one description of a
    /// widget, written once, reached the same way from the catalogue and
    /// from the widget's own header.
    ///
    /// The unavailability reason stays on the row, because it is not a
    /// description — it is the thing standing between the user and adding
    /// the widget, and burying it behind a button would hide the one line
    /// they can act on.
    private func entry(_ kind: DashboardWidgetKind, isPlaced: Bool) -> some View {
        // A placed widget carries no orange warning. It isn't a problem to
        // fix — the shelf it is sitting on already says why it can't be
        // added again.
        let reason = isPlaced ? nil : unavailable[kind]
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text(kind.title)
                    .font(AppTheme.Typography.rowTitle)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                infoButton(kind)
                Spacer(minLength: 0)
            }
            if let reason {
                Text(reason)
                    .font(AppTheme.Typography.label)
                    .foregroundStyle(AppTheme.Palette.brandPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if reason == nil, !isPlaced {
                draggableCard(kind)
            } else {
                // Still the real widget, still at its real size — the user
                // is being shown what they would get, and told what it
                // needs. It simply can't be picked up.
                preview(kind)
                    .opacity(AppTheme.Opacity.dim)
                    .saturation(0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { if reason == nil, !isPlaced { onSelect(kind) } }
        .accessibilityHint(reason ?? (isPlaced ? "Already on your dashboard" : ""))
    }

    /// Inside the row, but its own button — so the row's tap still adds the
    /// widget and only the glyph explains it.
    private func infoButton(_ kind: DashboardWidgetKind) -> some View {
        Button {
            explaining = kind
        } label: {
            Image(systemName: "info.circle")
                .font(AppTheme.Typography.label)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .hitTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About \(kind.title)")
    }

    /// The widget card, and the only part of the row a drag can start from.
    ///
    /// Attached to the whole row instead, the lift highlighted the row — the
    /// title, the size badge, the description and the card together, in one
    /// box that looked like a text selection rather than like picking up a
    /// widget. The lift shape comes from the source view, so the source view
    /// has to *be* the widget. Tapping anywhere on the row still adds it;
    /// only the grab moved.
    private func draggableCard(_ kind: DashboardWidgetKind) -> some View {
        preview(kind)
            // Clipped to the card's own corner, so the lift rounds off
            // exactly where the widget does rather than at a square edge a
            // few points outside it.
            .contentShape(
                .dragPreview,
                RoundedRectangle(cornerRadius: WidgetStyle.cornerRadius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: WidgetStyle.cornerRadius, style: .continuous))
            // SwiftUI calls this closure a second time when the drop
            // resolves the item — after the widget has already landed. So it
            // does one idempotent thing, note which kind is in hand, and the
            // dashboard acts on that note when the drag reaches it. Anything
            // with a consequence here (dismissing the panel, entering edit
            // mode, minting the arriving tile) would happen twice, the
            // second time stranding a widget nobody asked for.
            //
            // The payload itself cannot answer the question: a drop session
            // hands over its item data only in `performDrop`, and the grid
            // has to reflow around the widget long before then.
            .onDrag {
                onLift(kind)
                return NSItemProvider(object: kind.rawValue as NSString)
            } preview: {
                preview(kind)
            }
    }

    /// Rendered at exactly the cell size the dashboard would give it, so a
    /// 1×1 reads as half-width beside a 1×2's full width — the size badge and
    /// the picture agree, and the user learns the grid from the catalogue.
    /// Doubles as the drag preview, for the same reason.
    private func preview(_ kind: DashboardWidgetKind) -> some View {
        let size = geometry.size(rows: kind.baseSize.rows, columns: kind.baseSize.columns)
        return DashboardWidgetView(kind: kind, data: .sample)
            .frame(width: size.width, height: size.height)
            // A picture of a widget, not a widget: its own tap target would
            // compete with the row's, and its controls would invite
            // interaction that goes nowhere.
            .allowsHitTesting(false)
    }
}
