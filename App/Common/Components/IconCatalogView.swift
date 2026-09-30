import KeepoCore
import SwiftUI

/// The one icon+colour picker, shared by the Account and Category forms —
/// previously each form carried its own inline `LazyVGrid` of icons plus a
/// system `ColorPicker` row, which meant two lists to keep in step and two
/// different-looking ways to do the same job.
///
/// Presented as a sheet from the big round icon at the top of either form.
///
/// **It edits a draft and commits on the checkmark**, the same contract as
/// the ledger's filter sheets and `CustomColorSheet`: the cross — or a swipe
/// down — leaves the form exactly as it was. It used to write every tap
/// straight through to the form, with a lone "Done" that could only ever
/// agree, so there was no way to back out of a browse. The hero previews
/// the draft; the form underneath only changes on save.
struct IconCatalogView: View {
    @Binding private var savedIcon: String
    @Binding private var savedColor: Color
    /// Runs on the checkmark only — for a caller that needs to know the
    /// user made a choice even when it matches what was already there.
    /// `CategoryFormView` stops suggesting an icon from the name once one
    /// has been picked; a cancelled visit is not a pick.
    private let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var icon: String
    @State private var color: Color
    /// Colours mixed in `CustomColorSheet` during this visit, newest first.
    /// Shown in the swatch row at once, but only written to the device's
    /// recent colours on save — a cancelled visit leaves that list alone too.
    @State private var unsavedMixes: [String] = []
    @State private var isMixingColor = false
    /// Custom colours the user mixed themselves, most recent first.
    /// Device-local on purpose: this is a palette, not data about their
    /// money — nothing downstream reads it, and syncing it would mean a
    /// migration for a convenience list.
    @AppStorage(AppSettingsKeys.customIconColors) private var customColorsRaw = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: AppTheme.Spacing.m), count: 6)

    init(icon: Binding<String>, color: Binding<Color>, onSave: @escaping () -> Void = {}) {
        _savedIcon = icon
        _savedColor = color
        self.onSave = onSave
        _icon = State(initialValue: icon.wrappedValue)
        _color = State(initialValue: color.wrappedValue)
    }

    private var storedColors: [String] {
        customColorsRaw.split(separator: ",").map(String.init)
    }

    private var customColors: [String] {
        unsavedMixes + storedColors
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
                    .padding(.bottom, AppTheme.Spacing.l)
                    .frame(maxWidth: .infinity)
                    .background(AppTheme.Palette.bgCanvas)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
                        colorSection
                        iconSection
                    }
                    .padding(.horizontal, AppTheme.Spacing.l)
                    .padding(.bottom, AppTheme.Spacing.xxl)
                }
            }
            .background(AppTheme.Palette.bgCanvas)
            // Keyed off the selection itself, not a per-tile isSelected flag:
            // that flips on two tiles per tap (the old one and the new one)
            // and would fire the haptic twice.
            .sensoryFeedback(AppTheme.Feedback.selection, trigger: icon)
            .sensoryFeedback(AppTheme.Feedback.selection, trigger: color)
            .navigationTitle("Icon Catalogue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Discard changes")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: { Image(systemName: "checkmark") }
                        .accessibilityLabel("Use this icon and colour")
                }
            }
            .sheet(isPresented: $isMixingColor) {
                CustomColorSheet(initial: color) { mixed in
                    // Round-tripped through hex before being applied, so the
                    // swatch row and the stored value are the same colour —
                    // `hexString` is nil exactly when a colour cannot
                    // resolve to sRGB.
                    guard let hex = mixed.hexString else { return }
                    unsavedMixes = [hex] + unsavedMixes.filter { $0 != hex }
                    color = Color(hex: hex)
                }
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        CategoryIconView(icon: icon, color: color, diameter: AppTheme.Size.illustration)
            .frame(maxWidth: .infinity)
            .padding(.top, AppTheme.Spacing.m)
            // The preview is the whole point of this screen, so it should
            // visibly react rather than cutting between states.
            .animation(AppTheme.Motion.quick, value: icon)
            .animation(AppTheme.Motion.quick, value: color)
    }

    // MARK: - Colour

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            sectionTitle("Colour")
            LazyVGrid(columns: columns, spacing: AppTheme.Spacing.m) {
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
                .frame(height: AppTheme.Size.touchTarget)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(AppTheme.Typography.labelEmphasis)
                            .foregroundStyle(AppTheme.Palette.textOnAccent)
                    }
                }
                .overlay {
                    Circle().strokeBorder(AppTheme.Palette.textPrimary.opacity(isSelected ? 0.35 : 0), lineWidth: 2)
                }
        }
        .buttonStyle(.pressableCard)
        .accessibilityLabel("Colour \(hex)")
    }

    /// Opens `CustomColorSheet` on the first tap. This used to be the
    /// system `ColorPicker` laid transparently over the dashed circle, which
    /// writes through on **every** change: each colour the user merely
    /// browsed past in the picker landed in the recent-colours row and on
    /// the icon. The sheet holds a draft and commits once, on its checkmark.
    private var addColorSwatch: some View {
        Button {
            isMixingColor = true
        } label: {
            Circle()
                .strokeBorder(AppTheme.Palette.fillStrong, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .overlay {
                    Image(systemName: "plus")
                        .font(AppTheme.Typography.labelEmphasis)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                }
                .frame(height: AppTheme.Size.touchTarget)
                .contentShape(Circle())
        }
        .buttonStyle(.pressableCard)
        .accessibilityLabel("Choose a custom colour")
    }

    // MARK: - Icons

    private var iconSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
            sectionTitle("Icons")
            ForEach(families) { family in
                VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
                    Text(family.name)
                        .font(AppTheme.Typography.labelEmphasis)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                    LazyVGrid(columns: columns, spacing: AppTheme.Spacing.m) {
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
                .font(AppTheme.Typography.cardTitle)
                .foregroundStyle(isSelected ? AppTheme.Palette.textOnAccent : AppTheme.Palette.textPrimary)
                .frame(width: AppTheme.Size.touchTarget, height: AppTheme.Size.touchTarget)
                .background(isSelected ? color : AppTheme.Palette.bgSurface, in: Circle())
        }
        .buttonStyle(.pressableCard)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(AppTheme.Typography.rowTitle)
    }

    private func save() {
        // Oldest first, so the newest mix lands at the front of the list.
        unsavedMixes.reversed().forEach(remember)
        savedIcon = icon
        savedColor = color
        onSave()
        dismiss()
    }

    /// Newest first, de-duplicated, capped — a palette the user has to
    /// scroll is no longer a shortcut.
    private func remember(_ hex: String) {
        let updated = ([hex] + storedColors.filter { $0 != hex }).prefix(6)
        customColorsRaw = updated.joined(separator: ",")
    }
}

/// The system colour picker inside a sheet of Keepo's own, so that choosing
/// a colour has the same two exits as every other sheet in the app: a cross
/// that leaves everything as it was, and a checkmark that commits.
///
/// SwiftUI's `ColorPicker` offers neither. It presents
/// `UIColorPickerViewController` itself — eyedropper top left, close top
/// right — and writes to its binding on every change, so there was no
/// moment at which a colour counted as *chosen* rather than passed through.
/// Here the picker only ever edits `draft`, and nothing leaves the sheet
/// until the checkmark.
private struct CustomColorSheet: View {
    let onChoose: (Color) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: UIColor

    init(initial: Color, onChoose: @escaping (Color) -> Void) {
        self.onChoose = onChoose
        _draft = State(initialValue: UIColor(initial))
    }

    var body: some View {
        NavigationStack {
            SystemColorPicker(color: $draft)
                .ignoresSafeArea()
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Discard colour")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            onChoose(Color(uiColor: draft))
                            dismiss()
                        } label: {
                            Image(systemName: "checkmark")
                        }
                        .accessibilityLabel("Use this colour")
                    }
                }
        }
    }
}

/// `UIColorPickerViewController`, embedded rather than presented. Embedded,
/// it draws no close button of its own (UIKit adds one only when the picker
/// is itself the presentation), which is what leaves the sheet's toolbar as
/// the only way out. It keeps its own "Colors" header, which UIKit offers no
/// way to hide; the eyedropper in it can only be switched off from iOS 26.
private struct SystemColorPicker: UIViewControllerRepresentable {
    @Binding var color: UIColor

    func makeUIViewController(context: Context) -> UIColorPickerViewController {
        let picker = UIColorPickerViewController()
        picker.supportsAlpha = false
        if #available(iOS 26, *) { picker.supportsEyedropper = false }
        picker.selectedColor = color
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIColorPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(color: $color) }

    final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        private let color: Binding<UIColor>

        init(color: Binding<UIColor>) {
            self.color = color
        }

        func colorPickerViewController(
            _ picker: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool
        ) {
            self.color.wrappedValue = color
        }
    }
}
