import SwiftUI

/// The Custom period's picker: a calendar you scroll, rather than two
/// fields you set one at a time.
///
/// It replaces a `Form` holding two independent `DatePicker`s, which had
/// two problems. The small one is that two dates never showed the *shape*
/// of the period — you read "Aug 12" and "Aug 23" and did the arithmetic
/// yourself. The large one is that the two could disagree: nothing stopped
/// From landing after Through, and `TransactionsListView.range` handed that
/// pair straight to `DateInterval(start:end:)`, which **traps on a reversed
/// interval**. The app died where it stood. Here a tap before the start
/// begins a new selection instead, so the reversed pair has nowhere to come
/// from — the crash is closed at the layer that produced it, and `range`'s
/// own `max` is the backstop rather than the fix.
///
/// It edits a **draft** and commits once, on Done. The ledger underneath
/// reloads whenever the period changes, and half a selection — "from the
/// 12th to nowhere" — is not a period anyone asked to see.
struct CustomRangeSheet: View {
    let onDone: (Selection) -> Void

    /// What the sheet hands back. `range` is day-start bounds, inclusive at
    /// both ends; it is `nil` only when the user leaves with All Time on,
    /// where there is no range to carry.
    struct Selection {
        var range: ClosedRange<Date>?
        var isAllTime: Bool
    }

    @Environment(\.dismiss) private var dismiss
    // Not `private` from here down — read from CustomRangeSheet+Grid.swift,
    // an extension in a different file (kept there purely for file-length).
    @Environment(\.colorScheme) var colorScheme

    /// The first day of the selection. Never optional: the sheet always
    /// opens on the period already being looked at.
    @State var start: Date
    /// The last day, or `nil` while a selection is half made — which is
    /// also the one state Done refuses to commit.
    @State var end: Date?
    @State var isEverything: Bool
    @State var scrolledMonth: Date?

    let calendar = Calendar.current
    /// Computed once, in `init`. The window only has to cover what the user
    /// can reach, and they can only tap days this list draws.
    let months: [Date]

    init(from: Date, through: Date, isAllTime: Bool, onDone: @escaping (Selection) -> Void) {
        self.onDone = onDone
        let calendar = Calendar.current
        // `min`/`max`, not the arguments in order: a reversed pair is what
        // this sheet exists to make impossible, and it must not be able to
        // arrive from stale state either.
        let first = min(calendar.startOfDay(for: from), calendar.startOfDay(for: through))
        let last = max(calendar.startOfDay(for: from), calendar.startOfDay(for: through))
        _start = State(initialValue: first)
        _end = State(initialValue: last)
        _isEverything = State(initialValue: isAllTime)
        _scrolledMonth = State(initialValue: Self.monthStart(of: first, calendar: calendar))
        months = Self.monthWindow(covering: first...last, calendar: calendar)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.Palette.bgCanvas.ignoresSafeArea()

                // The reader wraps the header too, not just the scroll
                // view: "Jump to" lives up there and drives this same
                // proxy. A second reader inside would be a second
                // coordinate space that cannot reach these rows.
                ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                        HStack(spacing: AppTheme.Spacing.m) {
                            allTimeRow
                            jumpToMenu(proxy)
                        }
                        .padding(.horizontal, AppTheme.Spacing.l)
                        .padding(.bottom, AppTheme.Spacing.m)
                        weekdayHeader
                        calendarScroll(proxy)
                            .fadingEdges()
                            .opacity(isEverything ? AppTheme.Opacity.dim : 1)
                            .disabled(isEverything)
                        summaryBar
                    }
                }
                .padding(.top, AppTheme.Spacing.m)
            }
            .navigationTitle("Custom Range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { commit() } label: { Image(systemName: "checkmark") }
                        .disabled(end == nil && !isEverything)
                }
            }
        }
    }

    // MARK: - All Time

    /// A checkbox rather than a switch: a switch says "a setting that stays
    /// on", and this is one of the three answers to "which period" — it
    /// turns itself off the moment a date is tapped.
    ///
    /// Bare on the canvas, with no card behind it and no explanatory line
    /// under it. "All Time" needs neither: the calendar dimming beneath it
    /// says what it does more plainly than a sentence could.
    private var allTimeRow: some View {
        Button {
            isEverything.toggle()
        } label: {
            HStack(spacing: AppTheme.Spacing.m) {
                RoundedRectangle(cornerRadius: AppTheme.Radius.control / 2)
                    .strokeBorder(
                        isEverything ? AppTheme.Palette.brandPrimary : AppTheme.Palette.fillStrong, lineWidth: 1.5
                    )
                    .background(
                        isEverything ? AppTheme.Palette.brandPrimary : .clear,
                        in: RoundedRectangle(cornerRadius: AppTheme.Radius.control / 2)
                    )
                    .frame(width: AppTheme.Size.glyph, height: AppTheme.Size.glyph)
                    .overlay {
                        if isEverything {
                            Image(systemName: "checkmark")
                                .font(AppTheme.Typography.captionEmphasis)
                                .foregroundStyle(AppTheme.Palette.textOnAccent)
                        }
                    }

                Text("All Time")
                    .font(AppTheme.Typography.labelEmphasis)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, AppTheme.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableCard)
        .sensoryFeedback(AppTheme.Feedback.toggle, trigger: isEverything)
    }

    // MARK: - Selection

    /// Three rules, in this order, and the second is the one that closes
    /// the crash: **a tap before the start is a new start**, never an end
    /// that would sort before it.
    /// Not `private` — called from the grid in CustomRangeSheet+Grid.swift.
    /// Worth saying out loud here: while it was, the compiler did not
    /// complain about a missing method, it silently resolved `select(day)`
    /// to **Darwin's `select(2)`** and failed on its argument count. A
    /// cross-file `private` in this codebase can produce an error about a
    /// completely unrelated C function.
    func select(_ day: Date) {
        withAnimation(AppTheme.Motion.quick) {
            if end != nil || day < start {
                start = day
                end = nil
            } else {
                end = day
            }
        }
    }

    private func commit() {
        onDone(
            isEverything
                ? Selection(range: nil, isAllTime: true)
                : Selection(range: start...(end ?? start), isAllTime: false)
        )
        dismiss()
    }

    // MARK: - Summary

    /// Says what the taps add up to — including "how many days", which is
    /// the question two dates on their own never answered.
    private var summaryBar: some View {
        Text(summary)
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.Palette.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppTheme.Spacing.m)
    }

    private var summary: String {
        if isEverything { return "All Time" }
        guard let end else { return "Now pick the last day" }
        let days = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        let label = start == end
            ? start.formatted(date: .abbreviated, time: .omitted)
            : "\(start.formatted(date: .abbreviated, time: .omitted)) – "
                + end.formatted(date: .abbreviated, time: .omitted)
        return "\(label) · \(days) day\(days == 1 ? "" : "s")"
    }
}
