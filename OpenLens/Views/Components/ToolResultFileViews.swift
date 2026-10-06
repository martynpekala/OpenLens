import PDFKit
import SwiftUI
import UIKit

extension EnvironmentValues {
    /// Folder of the open chat session, used to read files tools return by path.
    @Entry var chatSessionDirectory: String?
}

/// Files a tool returned, shown under its transcript row. Files that can be
/// opened show a preview sheet; others explain why they can't be shown.
struct ToolResultFilesStrip: View {
    let files: [ToolResultFile]
    let omittedFileCount: Int
    let usesRetroTypography: Bool

    @State private var previewedFile: ToolResultFile?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(files) { file in
                            item(for: file)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            if omittedFileCount > 0 {
                Text(AppText.toolFilesNotShown(omittedFileCount))
                    .font(usesRetroTypography ? RetroChatStyle.smallFont : .caption)
                    .foregroundStyle(usesRetroTypography ? RetroChatStyle.mutedInk : Color.appSecondary)
            }
        }
        .sheet(item: $previewedFile) { file in
            ToolResultFilePreview(file: file)
        }
    }

    @ViewBuilder
    private func item(for file: ToolResultFile) -> some View {
        if file.kind == .image, case let .dataURI(uri) = file.source {
            Button {
                previewedFile = file
            } label: {
                PromptImageThumbnail(cacheKey: file.id, source: .dataURL(uri), side: 64)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(AppText.toolReturnedFile): \(file.title)")
            .accessibilityHint(AppText.openToolFile)
        } else if file.isInspectable {
            Button {
                previewedFile = file
            } label: {
                ToolResultFileChip(file: file, detail: nil)
            }
            .buttonStyle(.plain)
            .accessibilityHint(AppText.openToolFile)
        } else {
            ToolResultFileChip(file: file, detail: file.unavailableReason)
        }
    }
}

private struct ToolResultFileChip: View {
    let file: ToolResultFile
    let detail: String?

    private var systemImage: String {
        guard file.isInspectable else { return "doc.badge.ellipsis" }
        switch file.kind {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .text: return "doc.text"
        case .unsupported: return "doc"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
            VStack(alignment: .leading, spacing: 0) {
                Text(file.title)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .lineLimit(1)
                }
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel([AppText.toolReturnedFile + ": " + file.title, detail].compactMap(\.self).joined(separator: ", "))
    }
}

/// Read-only view of a file a tool returned, loaded when the sheet opens.
struct ToolResultFilePreview: View {
    let file: ToolResultFile

    private enum LoadState {
        case loading
        case failed(String)
        case loaded(ToolResultFileContent)
    }

    @Environment(\.workspaceService) private var workspaceService
    @Environment(\.chatSessionDirectory) private var sessionDirectory
    @Environment(\.dismiss) private var dismiss
    @State private var loadState: LoadState = .loading

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(file.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(AppText.done) { dismiss() }
                    }
                }
        }
        .task(id: file.id) {
            do {
                loadState = .loaded(try await workspaceService.loadToolResultFile(file, sessionDirectory: sessionDirectory))
            } catch is CancellationError {
                return
            } catch {
                loadState = .failed((error as? LocalizedError)?.errorDescription ?? AppText.toolFileCouldNotOpen)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailableView(AppText.toolFileCouldNotOpen, systemImage: "exclamationmark.triangle", description: Text(message))
        case let .loaded(.image(data)):
            if let image = UIImage(data: data) {
                ScrollView([.vertical, .horizontal]) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .containerRelativeFrame(.horizontal)
                        .accessibilityLabel(file.title)
                }
            } else {
                ContentUnavailableView(AppText.toolFileCouldNotOpen, systemImage: "photo", description: Text(AppText.toolFileUnreadable))
            }
        case let .loaded(.text(text)):
            ScrollView([.vertical, .horizontal]) {
                Text(AttachmentPreviewText.truncated(text))
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        case let .loaded(.pdf(data)):
            ToolResultPDFView(data: data)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

private struct ToolResultPDFView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}
