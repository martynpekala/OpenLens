import SwiftUI
import UniformTypeIdentifiers

struct RecordedReplayListView: View {
    enum ViewState {
        case idle
        case loading
        case loaded
        case error(String)
    }

    let onSelect: (RecordedChatReplay, RecordedReplayPlayer.PlaybackMode) -> Void

    @State private var viewState: ViewState = .idle
    @State private var descriptors: [RecordedChatReplay.Descriptor] = []
    @State private var exportDocument: RecordedReplayExportDocument?
    @State private var exportFilename: String?
    @State private var isExportingReplay = false

    @Environment(\.recordedReplayStore) private var recordedReplayStore

    private var isLoading: Bool {
        if case .loading = viewState { return true }
        return false
    }

    private var errorMessage: String? {
        if case .error(let message) = viewState { return message }
        return nil
    }

    var body: some View {
        Group {
            if isLoading && descriptors.isEmpty {
                ProgressView()
                    .tint(Color.appSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if descriptors.isEmpty {
                if let errorMessage {
                    errorState(message: errorMessage)
                } else {
                    emptyState
                }
            } else {
                replayList
            }
        }
        .background(Color.appBackground)
        .navigationTitle(AppText.captureBrowserTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadReplays()
        }
        .refreshable {
            await loadReplays()
        }
        .fileExporter(
            isPresented: $isExportingReplay,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result, !error.isUserCancelled {
                viewState = .error(AppText.recordedCaptureExportFailed(error.localizedDescription))
            }
            exportDocument = nil
            exportFilename = nil
        }
    }

    private var replayList: some View {
        List {
            if let errorMessage {
                errorBanner(message: errorMessage)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    .listRowBackground(Color.appBackground)
            }

            ForEach(descriptors) { descriptor in
                HStack(spacing: 12) {
                    Button {
                        play(descriptor, mode: .realtime)
                    } label: {
                        replayRow(descriptor)
                    }
                    .buttonStyle(.plain)

                    Menu {
                        Button(AppText.playRealtime) {
                            play(descriptor, mode: .realtime)
                        }
                        Button(AppText.playFast) {
                            play(descriptor, mode: .fast)
                        }
                        Button {
                            export(descriptor)
                        } label: {
                            Label(AppText.exportCapture, systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.appSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .listRowBackground(Color.appBackground)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        delete(descriptor)
                    } label: {
                        Label(AppText.delete, systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func replayRow(_ descriptor: RecordedChatReplay.Descriptor) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(descriptor.name)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.appPrimary)
                .lineLimit(1)

            Text(descriptor.sessionTitle ?? AppText.titleUntitled)
                .font(.system(size: 14))
                .foregroundStyle(Color.appSecondary)
                .lineLimit(1)

            HStack(spacing: 10) {
                Label(
                    descriptor.createdAt.formatted(date: .abbreviated, time: .shortened),
                    systemImage: "calendar"
                )

                Label(
                    AppText.captureEventCount(descriptor.eventCount),
                    systemImage: "waveform"
                )
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.appSecondary.opacity(0.85))
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.appTertiary)
                .frame(width: 72, height: 72)
                .overlay {
                    Image(systemName: "movieclapper")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Color.appSecondary)
                }

            VStack(spacing: 6) {
                Text(AppText.captureBrowserEmptyTitle)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appPrimary)

                Text(AppText.captureBrowserEmptySubtitle)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(Color.appSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.appTertiary)
                .frame(width: 72, height: 72)
                .overlay {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.orange)
                }

            VStack(spacing: 6) {
                Text(AppText.captureBrowserErrorTitle)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appPrimary)

                Text(message)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(Color.appSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 13))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Color.appSecondary)
            Spacer()
        }
    }

    @MainActor
    private func loadReplays() async {
        viewState = .loading

        do {
            descriptors = try recordedReplayStore.listReplays()
            viewState = .loaded
        } catch {
            viewState = .error(AppText.recordedCaptureLoadFailed(error.localizedDescription))
        }
    }

    private func play(_ descriptor: RecordedChatReplay.Descriptor, mode: RecordedReplayPlayer.PlaybackMode) {
        Task {
            do {
                let replay = try recordedReplayStore.loadReplay(descriptor)
                await MainActor.run {
                    viewState = .loaded
                    onSelect(replay, mode)
                }
            } catch {
                await MainActor.run {
                    viewState = .error(AppText.recordedCaptureOpenFailed(error.localizedDescription))
                }
            }
        }
    }

    private func delete(_ descriptor: RecordedChatReplay.Descriptor) {
        do {
            try recordedReplayStore.deleteReplay(descriptor)
            descriptors.removeAll { $0.id == descriptor.id }
            if descriptors.isEmpty {
                viewState = .loaded
            }
        } catch {
            viewState = .error(AppText.recordedCaptureDeleteFailed(error.localizedDescription))
        }
    }

    private func export(_ descriptor: RecordedChatReplay.Descriptor) {
        do {
            let export = try recordedReplayStore.exportReplay(descriptor)
            exportDocument = RecordedReplayExportDocument(data: export.data)
            exportFilename = export.filename
            isExportingReplay = true
            viewState = .loaded
        } catch {
            viewState = .error(AppText.recordedCaptureExportFailed(error.localizedDescription))
        }
    }
}

private extension Error {
    var isUserCancelled: Bool {
        let nsError = self as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }
}
