import ImageIO
import SwiftUI
import UIKit

/// A square thumbnail decoded off the main actor from image bytes or a
/// `data:` URL, downsampled so large photos don't hold full-size bitmaps.
struct PromptImageThumbnail: View {
    let cacheKey: String
    let source: Source
    let side: CGFloat

    enum Source: Sendable {
        case data(Data)
        case dataURL(String)
    }

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.quaternary)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: cacheKey) {
            image = await PromptImageThumbnailCache.thumbnail(
                key: cacheKey,
                source: source,
                maximumPixelSize: Int(side * displayScale)
            )
        }
    }
}

private enum PromptImageThumbnailCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 120
        return cache
    }()

    @MainActor
    static func thumbnail(key: String, source: PromptImageThumbnail.Source, maximumPixelSize: Int) async -> UIImage? {
        let cacheKey = "\(key)@\(maximumPixelSize)" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }
        let image = await Task.detached(priority: .userInitiated) {
            decode(source, maximumPixelSize: maximumPixelSize)
        }.value
        if let image { cache.setObject(image, forKey: cacheKey) }
        return image
    }

    private nonisolated static func decode(_ source: PromptImageThumbnail.Source, maximumPixelSize: Int) -> UIImage? {
        let data: Data?
        switch source {
        case let .data(bytes):
            data = bytes
        case let .dataURL(url):
            data = url.range(of: ";base64,").flatMap { Data(base64Encoded: String(url[$0.upperBound...])) }
        }
        guard let data,
              let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maximumPixelSize, 1),
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: thumbnail)
    }
}

/// Images and files attached to a user prompt, shown above its text.
struct MessageAttachmentsRow: View {
    let images: [OCPart]
    let files: [OCPart]

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(images, id: \.id) { part in
                        PromptImageThumbnail(
                            cacheKey: part.id,
                            source: .dataURL(part.url ?? ""),
                            side: images.count == 1 ? 160 : 96
                        )
                        .accessibilityLabel(part.filename ?? AppText.attachedImage)
                    }
                }
            }
            ForEach(files, id: \.id) { part in
                Label(part.filename ?? part.mime ?? AppText.attachedFile, systemImage: "doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// Images waiting in the composer, each removable before sending.
struct ComposerImageStrip: View {
    let images: [PromptImageAttachment]
    let isPreparing: Bool
    let onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images) { image in
                    PromptImageThumbnail(cacheKey: image.id, source: .data(image.data), side: 56)
                        .overlay(alignment: .topTrailing) {
                            Button {
                                onRemove(image.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                                    .font(.system(size: 18))
                            }
                            .buttonStyle(.plain)
                            .padding(2)
                            .accessibilityLabel(AppText.removeAttachedImage)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(AppText.attachedImage)
                }
                if isPreparing {
                    ProgressView()
                        .frame(width: 56, height: 56)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityLabel(AppText.preparingImage)
                }
            }
            .padding(.vertical, 2)
        }
    }
}
