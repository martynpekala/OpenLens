import SwiftUI

struct TurnFileChangesTimelineRow: View {
    private struct SelectedFile: Identifiable {
        let userMessageID: String
        let summary: TurnFileChangeSummary

        var id: String { "\(userMessageID):\(summary.path)" }
    }

    @Bindable var chatClient: ChatClient
    let message: ChatMessage

    @Environment(\.chatEasterEgg) private var chatEasterEgg
    @State private var showsAllFiles = false
    @State private var selectedFile: SelectedFile?
    @State private var didOpenPreviewFile = false

    private let collapsedFileLimit = 5

    var body: some View {
        HStack(alignment: .bottom, spacing: isRetroChat ? 6 : 8) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(visibleFiles) { file in
                    fileButton(file)
                }

                if hiddenFileCount > 0 {
                    Button("Show \(hiddenFileCount) more") {
                        showsAllFiles = true
                    }
                    .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 12, weight: .medium))
                    .foregroundStyle(isRetroChat ? RetroChatStyle.secondaryInk : Color.appSecondary)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show \(hiddenFileCount) more changed files")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: isRetroChat ? 24 : 32)
        }
        .sheet(item: $selectedFile) { selection in
            TurnFileDiffSheet(
                chatClient: chatClient,
                userMessageID: selection.userMessageID,
                summary: selection.summary
            )
        }
        .task {
            guard ScreenshotFixtures.opensTurnDiffSheet,
                  !didOpenPreviewFile,
                  let userMessageID = message.parentUserMessageID,
                  let firstFile = message.turnFileChanges.first else { return }
            didOpenPreviewFile = true
            selectedFile = SelectedFile(userMessageID: userMessageID, summary: firstFile)
        }
    }

    private var visibleFiles: ArraySlice<TurnFileChangeSummary> {
        if showsAllFiles {
            return message.turnFileChanges[...]
        }
        return message.turnFileChanges.prefix(collapsedFileLimit)
    }

    private var hiddenFileCount: Int {
        showsAllFiles ? 0 : max(0, message.turnFileChanges.count - collapsedFileLimit)
    }

    private var isRetroChat: Bool {
        chatEasterEgg.visualMode.isRetro
    }

    private func fileButton(_ file: TurnFileChangeSummary) -> some View {
        Button {
            guard let userMessageID = message.parentUserMessageID else { return }
            selectedFile = SelectedFile(userMessageID: userMessageID, summary: file)
        } label: {
            HStack(spacing: 12) {
                Text(file.filename)
                    .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(isRetroChat ? RetroChatStyle.secondaryInk : Color.appPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isRetroChat ? RetroChatStyle.secondaryInk : Color.appSecondary)
                    .fixedSize()
                    .accessibilityHidden(true)

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    Text("+\(file.additions)")
                        .foregroundStyle(isRetroChat ? RetroChatStyle.secondaryInk : .green)
                    Text("−\(file.deletions)")
                        .foregroundStyle(isRetroChat ? RetroChatStyle.danger : .red)
                }
                .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 12, weight: .semibold, design: .rounded))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(file.filename), \(file.additions) lines added, \(file.deletions) lines removed")
        .accessibilityHint("Opens the historical diff for \(file.path)")
    }
}

private struct TurnFileDiffSheet: View {
    private enum ViewState {
        case loading
        case loaded(ReviewFileChange)
        case failed(String)
    }

    @Bindable var chatClient: ChatClient
    let userMessageID: String
    let summary: TurnFileChangeSummary

    @Environment(\.dismiss) private var dismiss
    @State private var state = ViewState.loading
    @State private var loadAttempt = 0

    var body: some View {
        Group {
            switch state {
            case .loading:
                statusSheet {
                    ProgressView("Loading diff…")
                }
            case .loaded(let file):
                FileDiffDetailView(file: file)
            case .failed(let message):
                statusSheet {
                    VStack(spacing: 14) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28))
                            .foregroundStyle(Color.appWarning)

                        Text(message)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.appSecondary)
                            .multilineTextAlignment(.center)

                        Button("Retry") {
                            loadAttempt &+= 1
                        }
                        .primaryCTAStyle()
                    }
                    .padding(.horizontal, 32)
                }
            }
        }
        .task(id: loadAttempt) {
            await load()
        }
    }

    private func statusSheet<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.appBackground)
                .navigationTitle(summary.filename)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
        }
    }

    private func load() async {
        state = .loading
        do {
            let file = try await chatClient.loadTurnFileDetail(
                userMessageID: userMessageID,
                path: summary.path
            )
            guard !Task.isCancelled else { return }
            state = .loaded(file)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }
}
