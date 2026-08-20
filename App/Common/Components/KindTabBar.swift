import SwiftUI

/// The Expense / Income / Transfer selector at the top of the transaction
/// form. A plain `.segmented` `Picker` was what this used to be; it reads as
/// a settings control rather than a mode switch, and its filled capsule
/// fights the card underneath it.
///
/// This is deliberately background-free per the redesign: the selected item
/// is marked by weight and an underline, the way a tab bar marks a tab.
struct KindTabBar<Kind: Hashable & CaseIterable & Identifiable>: View where Kind.AllCases: RandomAccessCollection {
    @Binding var selection: Kind
    let title: (Kind) -> String
    /// Edit mode locks the kind — changing it is delete-and-recreate, never
    /// an in-place edit (app-architecture.md §2), so the bar renders the
    /// current kind and refuses the others rather than disappearing (which
    /// would leave the user unsure what they are editing).
    var isEnabled = true

    @Namespace private var underline

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(Kind.allCases)) { kind in
                tab(kind)
            }
        }
        .animation(.snappy(duration: 0.22), value: selection)
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func tab(_ kind: Kind) -> some View {
        let isSelected = kind == selection
        return Button {
            selection = kind
        } label: {
            VStack(spacing: 8) {
                Text(title(kind))
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(foreground(isSelected: isSelected))
                    .frame(maxWidth: .infinity)

                ZStack {
                    Capsule().fill(Color.clear).frame(height: 2)
                    if isSelected {
                        Capsule()
                            .fill(isEnabled ? Color.primary : Color.secondary)
                            .frame(height: 2)
                            .matchedGeometryEffect(id: "underline", in: underline)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableRow)
        .disabled(!isEnabled)
    }

    private func foreground(isSelected: Bool) -> Color {
        guard isEnabled else { return isSelected ? Color.secondary : Color.secondary.opacity(0.4) }
        return isSelected ? Color.primary : Color.secondary
    }
}
