import KeepoCore
import SwiftUI

/// How precisely a custom period can be named. Net worth and cashflow are
/// month-end figures, so asking for a day would offer a precision the data
/// doesn't have; an FX rate genuinely does move day to day.
enum TimeframePrecision {
    case monthYear
    case dayMonthYear
}

/// The W/M/Y/📅 control in an expanded widget's header — one component, used
/// by every widget that charts a series.
///
/// It is deliberately the *same* control as the pinch gesture rather than a
/// parallel one: zooming past a threshold writes back through this binding,
/// so the highlighted segment always describes what the chart is actually
/// drawing. A filter that kept saying "M" while the chart had zoomed out to
/// years would be worse than no filter.
struct TimeframeFilterView: View {
    let granularities: [MetricGranularity]
    var precision: TimeframePrecision = .monthYear
    @Binding var timeframe: MetricTimeframe

    @State private var isPickingPeriod = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(granularities) { granularity in
                segment(
                    label: { Text(granularity.label) },
                    isSelected: timeframe == .rolling(granularity),
                    action: { timeframe = .rolling(granularity) }
                )
            }
            segment(
                label: { Image(systemName: "calendar") },
                isSelected: timeframe.isCustom,
                action: { isPickingPeriod = true }
            )
            .accessibilityLabel("Custom period")
        }
        .font(.caption)
        // The border is what makes this read as *one control* rather than as
        // four loose letters floating in the header. Without it the segments
        // had no edge to aim at, so the only thing that looked tappable was
        // the glyph itself — which is exactly the target HIG says is too
        // small.
        .padding(.horizontal, 3)
        .overlay(Capsule().stroke(Color.secondary.opacity(0.35), lineWidth: 1))
        .sensoryFeedback(.selection, trigger: timeframe)
        .sheet(isPresented: $isPickingPeriod) {
            TimeframePeriodSheet(timeframe: $timeframe, precision: precision)
                .presentationDetents([.medium])
        }
    }

    private func segment(
        @ViewBuilder label: @escaping () -> some View, isSelected: Bool, action: @escaping () -> Void
    ) -> some View {
        WidgetSegment(isSelected: isSelected, action: action, label: label)
    }
}

/// The custom-period sheet behind the calendar segment.
///
/// "All time" is a checkbox rather than a third segment because it answers a
/// different question — not *which* period, but "don't ask me for one". When
/// it is on the pickers are disabled rather than hidden, so the control the
/// user is overriding stays visible.
private struct TimeframePeriodSheet: View {
    @Binding var timeframe: MetricTimeframe
    let precision: TimeframePrecision

    @Environment(\.dismiss) private var dismiss
    @State private var isAllTime: Bool
    @State private var start: Date
    @State private var end: Date

    init(timeframe: Binding<MetricTimeframe>, precision: TimeframePrecision) {
        _timeframe = timeframe
        self.precision = precision
        let today = Date()
        let yearAgo = Calendar.current.date(byAdding: .year, value: -1, to: today) ?? today
        if case .custom(let range) = timeframe.wrappedValue {
            _start = State(initialValue: range.lowerBound)
            _end = State(initialValue: range.upperBound)
        } else {
            _start = State(initialValue: yearAgo)
            _end = State(initialValue: today)
        }
        _isAllTime = State(initialValue: timeframe.wrappedValue == .allTime)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("All time", isOn: $isAllTime)
                        .tint(Color.accentColor)
                } footer: {
                    Text("Shows everything you have, fitted to the widget.")
                }
                Section {
                    picker("From", selection: $start, in: ...end)
                    picker("To", selection: $end, in: start ... Date())
                }
                .disabled(isAllTime)
            }
            .navigationTitle("Custom Period")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        timeframe = isAllTime ? .allTime : .custom(start ... end)
                        dismiss()
                    }
                }
            }
        }
    }

    /// A month-precision period still stores real dates — the chart has to
    /// know where inside the first and last month to start and stop. The
    /// precision only decides what the user is asked for; `boundedToMonth`
    /// snaps the answer.
    @ViewBuilder
    private func picker(
        _ title: String, selection: Binding<Date>, in range: PartialRangeThrough<Date>
    ) -> some View {
        switch precision {
        case .dayMonthYear:
            DatePicker(title, selection: selection, in: range, displayedComponents: .date)
        case .monthYear:
            MonthYearPicker(title: title, selection: selection, latest: range.upperBound)
        }
    }

    @ViewBuilder
    private func picker(_ title: String, selection: Binding<Date>, in range: ClosedRange<Date>) -> some View {
        switch precision {
        case .dayMonthYear:
            DatePicker(title, selection: selection, in: range, displayedComponents: .date)
        case .monthYear:
            MonthYearPicker(title: title, selection: selection, latest: range.upperBound)
        }
    }
}

/// Month and year, and nothing finer.
///
/// SwiftUI has no month-precision `DatePicker`, and a full one would offer a
/// day the underlying figures don't have — a net worth series is month-end
/// readings, so "from 17 March" and "from 1 March" are the same chart. Two
/// menus rather than two wheels: the header this sits under is a form row,
/// and a pair of wheels in a `Form` is a lot of furniture for two values.
private struct MonthYearPicker: View {
    let title: String
    @Binding var selection: Date
    /// Nothing after this can be picked — there is no data from the future.
    let latest: Date

    private var calendar: Calendar { .current }

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Picker("Month", selection: monthBinding) {
                ForEach(1 ... 12, id: \.self) { month in
                    Text(monthName(month)).tag(month)
                }
            }
            .labelsHidden()
            Picker("Year", selection: yearBinding) {
                ForEach(years, id: \.self) { year in
                    Text(verbatim: "\(year)").tag(year)
                }
            }
            .labelsHidden()
        }
    }

    /// Ten years back from the latest allowed date — long enough to cover
    /// any history this app can have, and bounded so the menu stays a menu.
    private var years: [Int] {
        let newest = calendar.component(.year, from: latest)
        return Array((newest - 10) ... newest)
    }

    private var monthBinding: Binding<Int> {
        Binding(
            get: { calendar.component(.month, from: selection) },
            set: { selection = date(month: $0, year: calendar.component(.year, from: selection)) }
        )
    }

    private var yearBinding: Binding<Int> {
        Binding(
            get: { calendar.component(.year, from: selection) },
            set: { selection = date(month: calendar.component(.month, from: selection), year: $0) }
        )
    }

    /// Clamped to `latest`, so picking December of the current year in
    /// August can't produce a range extending into the future.
    private func date(month: Int, year: Int) -> Date {
        let composed = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? selection
        return min(composed, latest)
    }

    private func monthName(_ month: Int) -> String {
        let symbols = calendar.shortMonthSymbols
        guard month >= 1, month <= symbols.count else { return "\(month)" }
        return symbols[month - 1]
    }
}
