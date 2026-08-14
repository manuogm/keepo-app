import SwiftUI

/// Period navigator (day/week/month/year/custom) — split out of
/// TransactionsListView.swift purely to keep that file under the project's
/// file-length/type-body-length lint thresholds.
extension TransactionsListView {
    var periodNavigator: some View {
        VStack(spacing: 8) {
            Picker("Period", selection: $period) {
                ForEach(Period.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: period) { _, newPeriod in
                if newPeriod == .custom { isCustomRangePresented = true }
            }

            if period != .custom {
                HStack {
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text(rangeLabel)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                    Spacer()
                    Button { step(1) } label: { Image(systemName: "chevron.right") }
                }
            } else {
                Button {
                    isCustomRangePresented = true
                } label: {
                    Text(rangeLabel)
                        .font(.subheadline)
                }
            }
        }
        .padding()
    }

    var customRangeSheet: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $customFrom, displayedComponents: .date)
                DatePicker("Through", selection: $customThrough, displayedComponents: .date)
            }
            .navigationTitle("Custom Range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { isCustomRangePresented = false } label: { Image(systemName: "checkmark") }
                }
            }
        }
    }

    var rangeLabel: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        switch period {
        case .day:
            formatter.dateFormat = "MMM d, yyyy"
            return formatter.string(from: anchor)
        case .week:
            formatter.dateFormat = "MMM d"
            let end = calendar.date(byAdding: .day, value: -1, to: range.end) ?? range.end
            return "\(formatter.string(from: range.start)) – \(formatter.string(from: end))"
        case .month:
            formatter.dateFormat = "MMMM yyyy"
            return formatter.string(from: anchor)
        case .year:
            formatter.dateFormat = "yyyy"
            return formatter.string(from: anchor)
        case .custom:
            formatter.dateFormat = "MMM d, yyyy"
            return "\(formatter.string(from: customFrom)) – \(formatter.string(from: customThrough))"
        }
    }

    func step(_ direction: Int) {
        guard let component = period.component else { return }
        anchor = calendar.date(byAdding: component, value: direction, to: anchor) ?? anchor
    }
}
