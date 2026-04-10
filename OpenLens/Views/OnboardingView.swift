import SwiftUI

/// Full-screen onboarding shown on first launch.
/// Four pages: start the server, connect, multi-client overview, attach to existing server.
struct OnboardingView: View {

    var onDone: () -> Void

    @State private var currentPage: Int = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            id: 0,
            icon: "qrcode.viewfinder",
            iconColor: Color.appPrimary,
            title: AppText.onboardingPageQRTitle,
            body: AppText.onboardingPageQRBody,
            hint: AppText.onboardingPageQRHint
        ),
        OnboardingPage(
            id: 1,
            icon: "terminal",
            iconColor: Color.appPrimary,
            title: AppText.onboardingPage1Title,
            body: AppText.onboardingPage1Body,
            hint: AppText.onboardingPage1Hint
        ),
        OnboardingPage(
            id: 2,
            icon: "macbook.and.iphone",
            iconColor: Color.appPrimary,
            title: AppText.onboardingPage2Title,
            body: AppText.onboardingPage2Body,
            hint: AppText.onboardingPage2Hint
        ),
        OnboardingPage(
            id: 3,
            icon: "macwindow.on.rectangle",
            iconColor: Color.appPrimary,
            title: AppText.onboardingPage3Title,
            body: AppText.onboardingPage3Body,
            hint: AppText.onboardingPage3Hint
        ),
        OnboardingPage(
            id: 4,
            icon: "arrow.triangle.2.circlepath",
            iconColor: Color.appPrimary,
            title: AppText.onboardingPage4Title,
            body: AppText.onboardingPage4Body,
            hint: AppText.onboardingPage4Hint
        )
    ]

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Pages
                TabView(selection: $currentPage) {
                    ForEach(pages) { page in
                        pageView(page)
                            .tag(page.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.3), value: currentPage)

                // Bottom controls
                bottomBar
            }
        }
    }

    // MARK: - Page

    private func pageView(_ page: OnboardingPage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Icon
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.appTertiary)
                    .frame(width: 72, height: 72)
                    .overlay {
                        Image(systemName: page.icon)
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(page.iconColor)
                    }

                // Step badge
                Text(AppText.onboardingStep(page.id + 1, pages.count))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color.appSeparator)
                    )

                // Title
                Text(page.title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.appPrimary)

                // Body — rendered as markdown
                Text(markdown(page.body))
                    .font(.system(size: 16, design: .rounded))
                    .foregroundStyle(Color.appPrimary.opacity(0.85))
                    .lineSpacing(4)

                // Hint card
                SurfaceCard {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lightbulb")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.appSecondary)
                            .padding(.top, 1)
                        Text(markdown(page.hint))
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(Color.appSecondary)
                            .lineSpacing(3)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 48)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 16) {
            // Page dots
            HStack(spacing: 6) {
                ForEach(0..<pages.count, id: \.self) { index in
                    Capsule()
                        .fill(index == currentPage ? Color.appPrimary : Color.appSeparator)
                        .frame(width: index == currentPage ? 20 : 6, height: 6)
                        .animation(.easeInOut(duration: 0.25), value: currentPage)
                }
            }

            if currentPage < pages.count - 1 {
                Button {
                    withAnimation { currentPage += 1 }
                } label: {
                    Text(AppText.onboardingNext)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.appOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.appAccent)
                        )
                }
            } else {
                Button(action: {
                    onDone()
                }) {
                    Text(AppText.onboardingStart)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.appOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.appAccent)
                        )
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 36)
        .background(Color.appBackground)
    }
}

// MARK: - Model

private struct OnboardingPage: Identifiable {
    let id: Int
    let icon: String
    let iconColor: Color
    let title: String
    let body: String
    let hint: String
}

private func markdown(_ source: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace
    )

    return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
}

#Preview {
    OnboardingView(onDone: {})
}
