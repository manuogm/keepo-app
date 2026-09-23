import KeepoCore
import SwiftUI

/// What another screen hands the Export screen to start from — today only the
/// Transactions list, whose accounts, period and filters arrive already
/// answered so the only question left is the format.
struct ExportRequest: Identifiable, Equatable {
    let id = UUID()
    /// `nil` means every account.
    let accountIds: Set<UUID>?
    let period: ExportPeriod
    let categoryId: UUID?
    let kind: String?
    let search: String?
}

/// Export, as three questions asked one per page — which accounts, which
/// period, which format — with progress dots in the bar and one button at the
/// bottom: "Continue", "Continue", "Export". The period page *is* the range
/// calendar, with All time and quick-pick pills over it; the count comes from
/// the same query the file will be built from, and is shown under the
/// calendar and over the last page's recap.
///
/// **One question per page, not three on one.** The first version of this
/// redesign was an accordion: every step on screen at once, the open one
/// expanded, a Continue inside the card and a second, disabled button in the
/// bar spelling out the next step. The user found it overwhelming, and it
/// was — two buttons for one move, and three cards competing before the
/// first was answered. Now each page asks one thing; the last page recaps
/// the earlier answers, each a tap away from its page.
///
/// **The pages slide inside one screen** rather than being pushed. Profile's
/// navigation path is typed to its own destinations and cannot hold these,
/// and a sheet over the Profile sheet to get real pushes would be heavier
/// than the problem. The cost is no edge-swipe between pages; the bar's back
/// chevron does that, as it does in onboarding.
///
/// **Arriving from the Transactions list** it opens on the last page with
/// accounts and period already answered from what the list was showing, and
/// any category, type or search filter as a removable chip — so "export what
/// I'm looking at" is one tap on a format and one on the button. Back still
/// walks through the earlier pages with those answers in place.
///
/// The security contract is unchanged from Phase 18: a fresh step-up
/// immediately before the file is built, and an audit row once it exists.
struct ExportView: View {
    let session: SessionStore
    var request: ExportRequest?
    /// Present only when this screen is its own sheet (from Transactions);
    /// pushed from Profile it has a back button instead.
    var onClose: (() -> Void)?

    enum Step: Int, CaseIterable {
        case accounts, period, format

        var previous: Step? { Step(rawValue: rawValue - 1) }
        var next: Step? { Step(rawValue: rawValue + 1) }
    }

    // Not `private` from here down — read and written from
    // ExportView+Steps.swift, an extension in a different file.
    @State var accounts: [LocalAccountRow] = []
    @State var categories: [PublicSchema.CategoriesSelect] = []
    @State var selection = ExportSelection()
    @State var step: Step = .accounts
    @State var entryCount: Int?
    /// The period page's calendar. The period itself is derived from it
    /// (`period(for:)`), never set beside it, so the pills, two taps and a
    /// pre-filled window all arrive at an answer the same way.
    @State var range = DayRange()
    @State var calendarFocus: Date?
    @State private var isLoaded = false
    @State private var isExporting = false
    @State private var actionError: ActionError?
    @State private var shared: SharedFile?
    @State private var exportsCompleted = 0

    let calendar = Calendar.current

    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()

            if isLoaded {
                VStack(spacing: 0) {
                    pager
                    bottomBar
                }
                // The bar measures from the screen's true bottom edge, so
                // the button's gap underneath equals its gap at the sides.
                // Ignoring the inset, not reading it: this bar first read
                // the home-indicator inset from its own geometry, the way
                // `OnboardingScaffold` does, and on the period page the
                // padding it produced moved the bar, which changed the inset
                // it read — a loop that pinned the main thread at 100%.
                .ignoresSafeArea(.container, edges: .bottom)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Export")
        .navigationBarTitleDisplayMode(.inline)
        // Past the first page the bar's own Back would leave the whole
        // export; the chevron below goes back one page instead.
        .navigationBarBackButtonHidden(step.previous != nil)
        .toolbar { toolbarContent }
        .onChange(of: step) { AccessibilityNotification.ScreenChanged(nil).post() }
        .onChange(of: range) { selection.period = period(for: range) }
        .task { await load() }
        .task(id: CountKey(selection: selection)) { await refreshCount() }
        .sheet(item: $shared) { file in
            ShareSheet(fileURL: file.url) { completed in
                // The file was only ever a vehicle for the share sheet; once
                // it has been handed over (or not), it has no reason to sit
                // in the container holding somebody's finances.
                try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
                shared = nil
                if completed { exportsCompleted += 1 }
            }
        }
        .sensoryFeedback(AppTheme.Feedback.success, trigger: exportsCompleted)
        .errorAlert($actionError)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let previous = step.previous {
            ToolbarItem(placement: .topBarLeading) {
                Button { go(to: previous) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Back")
            }
        }
        ToolbarItem(placement: .principal) {
            ProgressDots(current: step.rawValue, count: Step.allCases.count)
        }
        if let onClose {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onClose) { Image(systemName: "xmark") }
                    .accessibilityLabel("Close")
            }
        }
    }

    // MARK: - Pages

    /// The three pages side by side, the current one in view. An offset
    /// rather than a transition on a swapped view: a slide whose direction
    /// depends on whether the user went forward or back has to be decided on
    /// the page being *removed*, which SwiftUI renders with the transition it
    /// had before the tap — so a Back after a Continue slid the wrong way.
    /// Pages that are always there, moved by one number, cannot.
    private var pager: some View {
        GeometryReader { proxy in
            HStack(alignment: .top, spacing: 0) {
                ForEach(Step.allCases, id: \.self) { page in
                    pageContent(page)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                    .accessibilityHidden(page != step)
                    .allowsHitTesting(page == step)
                }
            }
            .offset(x: -proxy.size.width * CGFloat(step.rawValue))
        }
        // The neighbours sit just past the screen edges; a navigation pop or
        // a sheet's own slide would otherwise carry them into view.
        .clipped()
        .animation(AppTheme.Motion.standard, value: step)
    }

    /// The period page is the calendar, which scrolls itself; the other two
    /// scroll as a whole.
    @ViewBuilder
    private func pageContent(_ page: Step) -> some View {
        switch page {
        case .accounts: scrollingPage { accountsPage }
        case .period: periodPage
        case .format: scrollingPage { formatPage }
        }
    }

    private func scrollingPage(@ViewBuilder _ content: () -> some View) -> some View {
        ScrollView {
            content()
                .padding(.horizontal, AppTheme.Spacing.l)
                .padding(.top, AppTheme.Spacing.l)
                .padding(.bottom, AppTheme.Spacing.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    func go(to page: Step) {
        step = page
    }

    // MARK: - The bar

    /// One button — "Continue", then "Export" — with at most one line over
    /// it: what the period comes to on the period page, and on the last page
    /// that Face ID will be asked for.
    ///
    /// **Concentric with the screen**, like the setup flow's Next and the tab
    /// bar: `KeepoTabBarMetrics.margin` on the sides and underneath, from the
    /// screen's true bottom edge (the stack ignores the bottom safe area) —
    /// so the capsule's curve sits inside the device's own corner.
    private var bottomBar: some View {
        VStack(spacing: AppTheme.Spacing.s) {
            if let note = barNote {
                Text(note)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            PrimaryActionButton(
                title: step.next == nil ? "Export" : "Continue", isEnabled: isButtonEnabled,
                isLoading: isExporting, fillsWidth: true
            ) {
                if let next = step.next {
                    go(to: next)
                } else {
                    Task { await export() }
                }
            }
        }
        .padding(.horizontal, KeepoTabBarMetrics.margin)
        .padding(.top, AppTheme.Spacing.m)
        .padding(.bottom, KeepoTabBarMetrics.margin)
    }

    private var isButtonEnabled: Bool {
        switch step {
        case .accounts: return !selection.accountIds.isEmpty
        case .period: return selection.period != nil
        case .format: return selection.format != nil && (entryCount ?? 0) > 0 && !selection.accountIds.isEmpty
        }
    }

    private var barNote: String? {
        switch step {
        case .accounts: return nil
        case .period: return periodNote
        // Only while it is true: with the Face ID setting off, `stepUp`
        // returns without asking, and the line would be a promise the tap
        // does not keep.
        case .format: return AppSettings.isFaceIDEnabled ? "Face ID required" : nil
        }
    }

    /// "September 2026 · 42 transactions" — what the calendar comes to, so an
    /// empty period is found here, where picking another fixes it, rather
    /// than on the last page as a button that will not go. Between two taps
    /// it says what the second one is for.
    private var periodNote: String? {
        if !range.isAllTime, range.start != nil, range.end == nil { return "Now pick the last day" }
        guard let periodLabel, let entryCount else { return nil }
        let matching = selection.hasCarriedFilters ? "matching " : ""
        let count = entryCount == 0
            ? "No \(matching)transactions"
            : "\(entryCount) \(matching)transaction\(entryCount == 1 ? "" : "s")"
        return "\(periodLabel) · \(count)"
    }

    /// The answer the calendar gives: All Time, a preset when the days are
    /// exactly one, any other two days as a custom range, or nothing while a
    /// selection is half made.
    private func period(for range: DayRange) -> ExportPeriod? {
        if range.isAllTime { return .allTime }
        guard let days = range.days else { return nil }
        return .named(from: days.lowerBound, through: days.upperBound, now: Date(), calendar: calendar)
    }

    // MARK: - Loading

    private func load() async {
        guard !isLoaded, let ownerId = session.profile?.id, let baseCurrency = session.profile?.baseCurrency else {
            return
        }
        let loaded = try? await session.dbQueue.read { database in
            (
                try LocalAccountRow.fetchAll(database, ownerId: ownerId.uuidString, baseCurrency: baseCurrency),
                try LocalTableQueries.categories(database, ownerId: ownerId.uuidString)
            )
        }
        // Archived accounts are left out because the ledger leaves them out:
        // an export is the list the user was looking at, in a file.
        accounts = (loaded?.0 ?? []).filter { $0.archivedAt == nil }
        categories = loaded?.1 ?? []

        let everyAccount = Set(accounts.map(\.id))
        if let request {
            selection.accountIds = request.accountIds.map { $0.intersection(everyAccount) } ?? everyAccount
            if let days = request.period.days(now: Date(), calendar: calendar) {
                range = DayRange(start: days.lowerBound, end: days.upperBound)
            } else {
                range = DayRange(isAllTime: true)
            }
            selection.period = period(for: range)
            selection.categoryId = request.categoryId
            selection.kind = request.kind
            selection.search = request.search
            step = .format
        } else {
            // All accounts is a safe default — it is the superset, and the
            // first page shows it ticked. The period has no default: "this
            // month" and "everything" are both common and very different, so
            // the user says which.
            selection.accountIds = everyAccount
        }
        isLoaded = true
    }

    private func refreshCount() async {
        guard let filter = selection.filter(now: Date(), calendar: calendar), let ownerId = session.profile?.id else {
            entryCount = nil
            return
        }
        entryCount = try? await session.dbQueue.read { database in
            try LocalExportQueries.entryCount(database, filter: filter, ownerId: ownerId.uuidString)
        }
    }

    // MARK: - Export

    private func export() async {
        guard let format = selection.format,
              let filter = selection.filter(now: Date(), calendar: calendar),
              let ownerId = session.profile?.id,
              let baseCurrency = session.profile?.baseCurrency
        else { return }

        isExporting = true
        defer { isExporting = false }
        do {
            try await session.stepUp(reason: "Confirm it's you to export your financial data")
            let output = try await ExportBuilder.build(
                format, filter: filter,
                context: ExportBuilder.Context(
                    dbQueue: session.dbQueue, ownerId: ownerId.uuidString, baseCurrency: baseCurrency,
                    accountsLabel: accountsLabel, periodLabel: periodLabel ?? "Transactions"
                )
            )
            try await ExportRepository.logExport(
                client: session.client, accountIds: Array(selection.accountIds), rowCount: output.rowCount
            )
            shared = SharedFile(url: output.url)
        } catch {
            actionError = ActionError("Couldn't Export", error)
        }
    }

    /// Which inputs change the count — everything but the format.
    private struct CountKey: Equatable {
        let accountIds: Set<UUID>
        let period: ExportPeriod?
        let categoryId: UUID?
        let kind: String?
        let search: String?

        init(selection: ExportSelection) {
            accountIds = selection.accountIds
            period = selection.period
            categoryId = selection.categoryId
            kind = selection.kind
            search = selection.search
        }
    }

    private struct SharedFile: Identifiable {
        let url: URL
        var id: URL { url }
    }
}

/// The system share sheet, reporting whether the file actually went
/// somewhere — so the screen can clean up after it and confirm success.
private struct ShareSheet: UIViewControllerRepresentable {
    let fileURL: URL
    let onComplete: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in onComplete(completed) }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
