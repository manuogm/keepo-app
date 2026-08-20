import SwiftUI

/// The custom-range picker behind the Net Worth widget's "Custom" filter.
/// Two dates and a Done button — deliberately not a calendar-range control,
/// which iOS has no first-party version of and which would be a lot of
/// bespoke UI for a filter on one widget.
///
/// The bound range is only written on Done, so backing out leaves whatever
/// range was already in effect rather than half-applying a new one.
struct DateRangePickerSheet: View {
    @Binding var range: ClosedRange<Date>?

    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var end: Date

    init(range: Binding<ClosedRange<Date>?>) {
        _range = range
        let today = Date()
        let monthAgo = Calendar.current.date(byAdding: .month, value: -1, to: today) ?? today
        _start = State(initialValue: range.wrappedValue?.lowerBound ?? monthAgo)
        _end = State(initialValue: range.wrappedValue?.upperBound ?? today)
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $start, in: ...end, displayedComponents: .date)
                DatePicker("To", selection: $end, in: start...Date(), displayedComponents: .date)
            }
            .navigationTitle("Custom Range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        range = start...end
                        dismiss()
                    }
                }
            }
        }
    }
}
