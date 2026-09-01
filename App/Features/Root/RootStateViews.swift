import SwiftUI

/// Small, stateless views for `RootView`'s launch/error/privacy-curtain
/// states — kept together since none of them are reusable outside the
/// root router, unlike `Common/Components`.
struct RootLoadingView: View {
    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()
            VStack(spacing: AppTheme.Spacing.m) {
                ProgressView()
                Text("Keepo")
                    .font(AppTheme.Typography.sectionTitle).fontWeight(.bold)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
            }
        }
    }
}

struct RootPrivacyCurtainView: View {
    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()
            Text("Keepo")
                .font(AppTheme.Typography.sectionTitle).fontWeight(.bold)
                .foregroundStyle(AppTheme.Palette.textPrimary)
        }
    }
}

struct RootErrorView: View {
    let message: String

    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()
            VStack(spacing: AppTheme.Spacing.m) {
                Text("Couldn't connect")
                    .font(AppTheme.Typography.sectionTitle).fontWeight(.bold)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                Text(message)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
    }
}
