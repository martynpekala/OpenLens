import SwiftUI

/// Identifies the glass shapes that merge into the session picker control.
/// Explicitly `nonisolated` because the module defaults to `MainActor`
/// isolation, and `glassEffectUnion(id:namespace:)` needs a `Sendable` id.
private nonisolated enum ReviewSessionPickerGlassUnion: Hashable {
    case sessionPicker
}

/// Toolbar element showing the reviewed session on top and the change totals of
/// the current selection in a smaller capsule underneath. The two capsules are
/// merged into a single glass shape, so the whole thing reads and behaves as one
/// control. Tapping it opens a paginated dropdown list of sessions.
struct ReviewSessionPickerCapsule: View {
    struct ChangeTotals: Equatable {
        let additions: Int
        let deletions: Int

        static let zero = ChangeTotals(additions: 0, deletions: 0)
    }

    let title: String
    let totals: ChangeTotals
    let isPresented: Bool
    let action: () -> Void

    @Namespace private var glassNamespace

    var body: some View {
        Button(action: action) {
            GlassEffectContainer(spacing: 6) {
                VStack(spacing: 2) {
                    titleCapsule
                    totalsCapsule
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(AppText.reviewPickerHint)
    }

    private var titleCapsule: some View {
        GlassToolbarCapsule(isInteractive: true) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.appPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.appSecondary)
                .rotationEffect(.degrees(isPresented ? 180 : 0))
                .animation(.snappy, value: isPresented)
        }
    }

    /// Always mounted so the merged shape never changes. It starts at zero and
    /// counts up to the real totals once the review snapshot is loaded.
    private var totalsCapsule: some View {
        HStack(spacing: 8) {
            Text("+\(totals.additions)")
                .foregroundStyle(Color.appSuccess)
                .contentTransition(.numericText(value: Double(totals.additions)))
            Text("-\(totals.deletions)")
                .foregroundStyle(Color.appDanger)
                .contentTransition(.numericText(value: Double(totals.deletions)))
        }
        .font(.caption2.weight(.semibold))
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .glassEffect(.regular.interactive(), in: Capsule())
        .animation(.snappy(duration: 0.28), value: totals)
    }

    private var accessibilityLabel: String {
        AppText.reviewPickerAccessibility(
            title: title,
            additions: totals.additions,
            deletions: totals.deletions
        )
    }
}

/// Dropdown content listing sessions page by page. Reaching the end of the
/// list requests the next page through `onLoadMore`.
struct ReviewSessionPickerList: View {
    enum PagingState: Equatable {
        case idle
        case loading
        case error(String)
    }

    let options: [ReviewPickerOption]
    /// `ReviewPickerOption.id` of the reviewed session.
    let selectedOptionID: String?
    let hasMore: Bool
    let pagingState: PagingState
    let onSelect: (ReviewPickerOption) -> Void
    let onLoadMore: () async -> Void

    var body: some View {
        List {
            ForEach(options) { option in
                Button {
                    onSelect(option)
                } label: {
                    row(option)
                }
                .tint(.primary)
            }

            if hasMore {
                pagingRow
            }
        }
        .listStyle(.plain)
        .overlay {
            if options.isEmpty, !hasMore {
                ContentUnavailableView(AppText.reviewEmptyTitle, systemImage: "doc.text.magnifyingglass")
            }
        }
    }

    private func row(_ option: ReviewPickerOption) -> some View {
        let session = option.session
        let isSelected = option.id == selectedOptionID
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title.nilIfBlank ?? AppText.titleUntitled)
                    .lineLimit(1)
                if option.tag != nil || session.updatedAt > 0 {
                    HStack(spacing: 4) {
                        if let tag = option.tag {
                            ServerBadge(tag: tag, truncation: .tail)
                            if session.updatedAt > 0 {
                                Text("\u{00B7}")
                                    .font(.caption)
                                    .foregroundStyle(Color.appSecondary)
                            }
                        }
                        if session.updatedAt > 0 {
                            Text(Date(timeIntervalSince1970: session.updatedAt), format: .relative(presentation: .named))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.appAccent)
            }
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var pagingRow: some View {
        switch pagingState {
        case .error(let message):
            Button {
                Task { await onLoadMore() }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Label(AppText.reviewPickerLoadMore, systemImage: "arrow.clockwise")
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        case .idle, .loading:
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .listRowSeparator(.hidden)
            .task(id: options.count) {
                await onLoadMore()
            }
        }
    }
}
