import SwiftUI

/// What the screen shows while Delete Account runs: the splash's teal and
/// white K, with "Deleting all your data" over a bar where the splash has
/// its spinner.
///
/// Presented over the whole app — Profile included — the moment the step-up
/// passes, so nothing of the account being erased is still on screen while
/// it goes. It never dismisses on success: `signOut` swaps the root to the
/// sign-in screen underneath and takes this with it.
///
/// The deletion is one request with nothing to count, so the bar is paced
/// by time, not by work: it eases towards `ceiling` and stops short of
/// full, so it never claims a deletion that has not finished.
struct AccountDeletionView: View {
    /// Roughly what the Edge Function takes, cold start included — long
    /// enough that a normal deletion ends while the bar is still moving.
    private static let expectedDuration: TimeInterval = 4
    private static let ceiling = 0.9

    /// Same mark, same size, same place as `RootLoadingView`, so this reads
    /// as the app's own ground rather than a new screen.
    private static let markHeight = AppTheme.Size.illustration

    @State private var progress = 0.0

    var body: some View {
        ZStack {
            AppTheme.Palette.launchBackground
            Image("LaunchMark")
                .resizable()
                .scaledToFit()
                .frame(height: Self.markHeight)
            VStack(spacing: AppTheme.Spacing.m) {
                Text("Deleting all your data")
                    .font(AppTheme.Typography.labelEmphasis)
                ProgressView(value: progress)
                    .tint(AppTheme.Palette.textOnAccent)
            }
            .foregroundStyle(AppTheme.Palette.textOnAccent)
            .frame(maxWidth: AppTheme.Size.proseWidth)
            // Top-aligned under the mark at the splash spinner's offset:
            // centred, the stack's own height would push the text up into
            // the mark.
            .alignmentGuide(VerticalAlignment.center) { $0[.top] }
            .offset(y: Self.markHeight / 2 + AppTheme.Spacing.xl)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeOut(duration: Self.expectedDuration)) { progress = Self.ceiling }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Deleting all your data")
        .accessibilityAddTraits(.updatesFrequently)
    }
}

#Preview {
    AccountDeletionView()
}
