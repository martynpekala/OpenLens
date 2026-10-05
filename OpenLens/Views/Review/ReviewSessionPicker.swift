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
        .accessibilityHint("Choose another session to review")
    }

    private var titleCapsule: some View {
        HStack(spacing: 6) {
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
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(maxWidth: 240)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    /// Always mounted so the merged shape never changes. It starts at zero and
    /// counts up to the real totals once the review snapshot is loaded.
    private var totalsCapsule: some View {
        HStack(spacing: 8) {
            Text("+\(totals.additions)")
                .foregroundStyle(.green)
                .contentTransition(.numericText(value: Double(totals.additions)))
            Text("-\(totals.deletions)")
                .foregroundStyle(.red)
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
        "Reviewed session, \(title), \(totals.additions) lines added, \(totals.deletions) lines removed"
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

    let sessions: [OCSession]
    let selectedSessionID: String?
    let hasMore: Bool
    let pagingState: PagingState
    let onSelect: (OCSession) -> Void
    let onLoadMore: () async -> Void

    var body: some View {
        List {
            ForEach(sessions) { session in
                Button {
                    onSelect(session)
                } label: {
                    row(session)
                }
                .tint(.primary)
            }

            if hasMore {
                pagingRow
            }
        }
        .listStyle(.plain)
        .overlay {
            if sessions.isEmpty, !hasMore {
                ContentUnavailableView("No Sessions", systemImage: "doc.text.magnifyingglass")
            }
        }
    }

    private func row(_ session: OCSession) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title.nilIfBlank ?? AppText.titleUntitled)
                    .lineLimit(1)
                if session.updatedAt > 0 {
                    Text(Date(timeIntervalSince1970: session.updatedAt), format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if session.id == selectedSessionID {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.appAccent)
            }
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(session.id == selectedSessionID ? .isSelected : [])
    }

    @ViewBuilder
    private var pagingRow: some View {
        switch pagingState {
        case .error(let message):
            Button {
                Task { await onLoadMore() }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Load more sessions", systemImage: "arrow.clockwise")
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
            .task(id: sessions.count) {
                await onLoadMore()
            }
        }
    }
}
