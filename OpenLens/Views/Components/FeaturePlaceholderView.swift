import SwiftUI

struct FeaturePlaceholderView: View {
    let title: String
    let subtitle: String
    let symbol: String
    let highlights: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionLabel(text: title.uppercased())

                SurfaceCard {
                    HStack(spacing: 16) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.appTertiary)
                                .frame(width: 56, height: 56)
                            Image(systemName: symbol)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(Color.appPrimary)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text(title)
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.appPrimary)
                            Text(subtitle)
                                .font(.system(size: 15))
                                .foregroundStyle(Color.appSecondary)
                        }
                    }
                }

                SurfaceCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(highlights.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Color.appPrimary)
                                Text(item)
                                    .font(.system(size: 15, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.appPrimary)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)

                            if index < highlights.count - 1 {
                                SurfaceDivider()
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
        .background(Color.appBackground)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
