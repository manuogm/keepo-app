import SwiftUI

/// The app's own floating tab bar: three icon-only destinations in one
/// capsule, and the Add button as a **separate** object beside it.
///
/// It is hand-built rather than a styled `TabView` bar for one reason the
/// system bar cannot give: the Add button is not a tab. It has no selected
/// state, it never navigates, and what it adds depends on where you are —
/// a widget, an account, a transaction. Putting it inside the tab bar would
/// have made it look like a fourth destination; putting it outside says
/// "this acts on the screen you're on", which is exactly what it does.
///
/// Both the bar and the button are **neutral**: selection is weight and
/// contrast, not a colour fill. The screens themselves are now colour —
/// each one wears its scope's — so a coral pill down here was a second
/// thing competing to say where you are.
///
/// `TabView` still owns selection and keeps each tab's state alive; its own
/// bar is hidden per tab (`.toolbar(.hidden, for: .tabBar)`) and this rides
/// over the content as an overlay, reserving no row of its own — see
/// `KeepoTabBarMetrics.clearance` for what every scrolling view leaves
/// below its last row instead.
struct KeepoTabBar: View {
    @Binding var tab: AppNavigation.Tab
    /// Drawn as a dot on the Transactions icon — the Needs Review inbox
    /// lives on that screen now, so that is the tab that has to say when
    /// something is waiting.
    let needsReviewCount: Int
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: KeepoTabBarMetrics.gap) {
            destinations
            addButton
        }
        .padding(.horizontal, KeepoTabBarMetrics.margin)
    }

    private var destinations: some View {
        HStack(spacing: 0) {
            ForEach(AppNavigation.Tab.allCases, id: \.self) { destination in
                tabButton(destination)
            }
        }
        .frame(height: KeepoTabBarMetrics.height)
        .frame(maxWidth: .infinity)
        .liquidGlass(in: Capsule())
        .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
    }

    private func tabButton(_ destination: AppNavigation.Tab) -> some View {
        let isSelected = tab == destination
        return Button {
            guard !isSelected else { return }
            tab = destination
        } label: {
            VStack(spacing: 2) {
                Image(systemName: isSelected ? destination.selectedIcon : destination.icon)
                    .font(.system(size: 20, weight: .medium))
                    // A fixed box, because these three glyphs are not the
                    // same height: `list.bullet.rectangle.portrait` is taller
                    // than `creditcard`, so laid out naturally each label sat
                    // on its own baseline and the row read as crooked.
                    .frame(height: 23)
                    // Sits *outside* the icon, and mango rather than coral —
                    // this is the one thing in the bar allowed a colour,
                    // because it is the one thing reporting a fact rather
                    // than a location.
                    .overlay(alignment: .topTrailing) {
                        if destination == .transactions && needsReviewCount > 0 {
                            Circle()
                                .fill(Color(hex: "#FF9F1C"))
                                .frame(width: 7, height: 7)
                                .offset(x: 6, y: -2)
                        }
                    }
                Text(destination.label)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: KeepoTabBarMetrics.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.22), value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var addButton: some View {
        Button(action: onAdd) {
            Image(systemName: "plus")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: KeepoTabBarMetrics.height, height: KeepoTabBarMetrics.height)
                .liquidGlass(in: Circle())
                .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
        }
        .buttonStyle(.pressableCard)
        .accessibilityLabel(tab.addLabel)
    }
}

extension AppNavigation.Tab {
    var icon: String {
        switch self {
        case .home: return "square.grid.2x2"
        case .accounts: return "creditcard"
        case .transactions: return "list.bullet.rectangle.portrait"
        }
    }

    var selectedIcon: String {
        switch self {
        case .home: return "square.grid.2x2.fill"
        case .accounts: return "creditcard.fill"
        case .transactions: return "list.bullet.rectangle.portrait.fill"
        }
    }

    var label: String {
        switch self {
        case .home: return "Dashboard"
        case .accounts: return "Accounts"
        case .transactions: return "Transactions"
        }
    }

    var addLabel: String {
        switch self {
        case .home: return "Add a widget"
        case .accounts: return "Add an account"
        case .transactions: return "Add a transaction"
        }
    }
}

private extension View {
    /// iOS 26's Liquid Glass where it exists, the older material blur
    /// where it doesn't — the deployment target is still 18.0. Both draw
    /// their own edge, so nothing here adds a border of its own.
    @ViewBuilder
    func liquidGlass(in shape: some Shape) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
        }
    }
}

/// Shared because the bar floats *over* the screens rather than reserving a
/// strip of its own, so every scrolling view has to know how far to let its
/// last row travel before the glass eats it. One number, not four guesses.
///
/// **On the numbers.** The bar and the Add button are the same height and
/// sit the same distance from the left, right and bottom edges, so their
/// corners run **concentric** with the display's own: a rounded corner
/// nested inside another looks right only when the inner radius is the
/// outer one minus the gap between them. Half of 54 is 27, so a 30pt margin
/// implies a 57pt display corner — between the 55pt and 62pt of the phones
/// this ships to, and close enough on either that the curves read as
/// parallel. There is no public API for the real radius (the only way to
/// read it is a private `UIScreen` key), so this is calibrated, not
/// derived — if it ever looks wrong on a new device, `margin` is the number
/// to move.
enum KeepoTabBarMetrics {
    static let height: CGFloat = 54
    static let gap: CGFloat = 16
    /// The same on the sides and the bottom — a uniform margin is half of
    /// what makes the corners concentric; matching radii are the other half.
    static let margin: CGFloat = 30
    /// Where the bar's top edge sits above the bottom of the display — the
    /// line content has to be gone by, and so the length of the bottom fade
    /// (`FadingEdges`).
    static let topEdge: CGFloat = margin + height
    /// How much room a scrolling view must leave below its last row.
    static let clearance: CGFloat = topEdge + 10
}
