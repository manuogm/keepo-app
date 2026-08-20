import KeepoCore
import SwiftUI

/// The one icon+colour picker, shared by the Account and Category forms —
/// previously each form carried its own inline `LazyVGrid` of icons plus a
/// system `ColorPicker` row, which meant two lists to keep in step and two
/// different-looking ways to do the same job.
///
/// Presented as a sheet from the big round icon at the top of either form.
/// Selection is applied live to the bindings so the hero preview at the top
/// of this sheet, and the form underneath it, never disagree.
struct IconCatalogView: View {
    @Binding var icon: String
    @Binding var color: Color

    @Environment(\.dismiss) private var dismiss
    /// Bound directly to the inline `ColorPicker` that replaced the old
    /// custom-colour sheet — see `addColorSwatch`.
    @State private var customDraft = Color.accentColor
    /// Custom colours the user mixed themselves, most recent first.
    /// Device-local on purpose: this is a palette, not data about their
    /// money — nothing downstream reads it, and syncing it would mean a
    /// migration for a convenience list.
    @AppStorage(AppSettingsKeys.customIconColors) private var customColorsRaw = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 6)

    private var customColors: [String] {
        customColorsRaw.split(separator: ",").map(String.init)
    }

    /// Exactly two rows, with the "+" occupying the last cell — eleven
    /// swatches plus the button. A colour row the user has to read is not a
    /// shortcut; anything that does not fit is reachable through "+" anyway.
    /// Custom colours lead, so the one just mixed is where the eye already is.
    private var swatches: [String] {
        var seen = Set<String>()
        let ordered = (customColors + CategoryAppearance.palette).filter { seen.insert($0).inserted }
        // Whatever is currently selected must always be visible, even if it
        // has aged out of the recent list — otherwise the grid shows no
        // checkmark and the screen looks like nothing is chosen.
        let selected = color.hexString
        var visible = Array(ordered.prefix(Self.swatchCapacity))
        if let selected, !visible.contains(selected) {
            visible = [selected] + visible.dropLast()
        }
        return visible
    }

    private static let swatchCapacity = 11

    /// A stored icon that predates this catalogue (or came from an older
    /// default) would otherwise appear nowhere and read as "nothing is
    /// selected". Surfacing it as its own leading family is honest and
    /// keeps the grid's highlight meaningful.
    private var families: [IconLibrary.Family] {
        guard !IconLibrary.allIcons.contains(icon) else { return IconLibrary.families }
        return [IconLibrary.Family(name: "Current", icons: [icon])] + IconLibrary.families
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Outside the ScrollView on purpose. This is the answer to
                // the question the whole screen asks — scrolling to the
                // bottom of the icon grid and no longer being able to see
                // what you have picked makes every tap a guess.
                hero
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity)
                    .background(Color(.systemGroupedBackground))

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        colorSection
                        iconSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
            }
            .background(Color(.systemGroupedBackground))
            // Keyed off the selection itself, not a per-tile isSelected flag:
            // that flips on two tiles per tap (the old one and the new one)
            // and would fire the haptic twice.
            .sensoryFeedback(.selection, trigger: icon)
            .sensoryFeedback(.selection, trigger: color)
            .navigationTitle("Icon Catalogue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        CategoryIconView(icon: icon, color: color, diameter: 96)
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            // The preview is the whole point of this screen, so it should
            // visibly react rather than cutting between states.
            .animation(.snappy(duration: 0.2), value: icon)
            .animation(.snappy(duration: 0.2), value: color)
    }

    // MARK: - Colour

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Colour")
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(swatches, id: \.self) { hex in
                    swatch(hex)
                }
                addColorSwatch
            }
        }
    }

    private func swatch(_ hex: String) -> some View {
        let swatchColor = Color(hex: hex)
        let isSelected = color.hexString == hex
        return Button {
            color = swatchColor
        } label: {
            Circle()
                .fill(swatchColor)
                .frame(height: 40)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .overlay {
                    Circle().strokeBorder(Color.primary.opacity(isSelected ? 0.35 : 0), lineWidth: 2)
                }
        }
        .buttonStyle(.pressableCard)
        .accessibilityLabel("Colour \(hex)")
    }

    /// The system `ColorPicker` itself, laid transparently over the dashed
    /// circle. It was previously a button opening our own sheet that then
    /// opened the system picker — two taps and a screen to choose a colour.
    /// `ColorPicker` draws its own swatch, so it is hidden behind ours and
    /// only its tap target is used; the picker now opens on the first tap.
    private var addColorSwatch: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }

            ColorPicker("Custom colour", selection: $customDraft, supportsOpacity: false)
                .labelsHidden()
                .opacity(0.02)
        }
        .frame(height: 40)
        .onChange(of: customDraft) { _, newValue in
            // Round-tripped through hex before being applied, so the swatch
            // row and the stored value are the same colour — `hexString` is
            // nil exactly when a colour cannot resolve to sRGB.
            guard let hex = newValue.hexString else { return }
            remember(hex)
            color = Color(hex: hex)
        }
        .accessibilityLabel("Choose a custom colour")
    }

    // MARK: - Icons

    private var iconSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionTitle("Icons")
            ForEach(families) { family in
                VStack(alignment: .leading, spacing: 10) {
                    Text(family.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.secondary)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(family.icons, id: \.self) { candidate in
                            iconTile(candidate)
                        }
                    }
                }
            }
        }
    }

    private func iconTile(_ candidate: String) -> some View {
        let isSelected = icon == candidate
        return Button {
            icon = candidate
        } label: {
            Image(systemName: candidate)
                .font(.system(size: 19))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(width: 44, height: 44)
                .background(isSelected ? color : Color(.secondarySystemGroupedBackground), in: Circle())
        }
        .buttonStyle(.pressableCard)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
    }

    /// Newest first, de-duplicated, capped — a palette the user has to
    /// scroll is no longer a shortcut.
    private func remember(_ hex: String) {
        let updated = ([hex] + customColors.filter { $0 != hex }).prefix(6)
        customColorsRaw = updated.joined(separator: ",")
    }
}
