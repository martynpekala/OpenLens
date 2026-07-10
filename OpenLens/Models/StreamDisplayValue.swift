import Foundation

/// Creates bounded values for server strings that become observable UI state.
/// It operates on a short UTF-8 prefix so the UI actor never has to inspect a
/// full untrusted value merely to render a one-line label.
nonisolated enum StreamDisplayValue {
    static let maximumIdentifierBytes = 256

    static func preview(_ value: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }

        var fullPreview = String.UnicodeScalarView()
        var fullPreviewByteCount = 0
        var wasTruncated = false

        for scalar in value.unicodeScalars {
            let byteCount = scalar.utf8.count
            guard fullPreviewByteCount + byteCount <= maximumBytes else {
                wasTruncated = true
                break
            }
            fullPreview.append(scalar)
            fullPreviewByteCount += byteCount
        }

        guard wasTruncated else { return value }

        let suffix = "…"
        let contentLimit = max(maximumBytes - suffix.utf8.count, 0)
        var content = String.UnicodeScalarView()
        var contentByteCount = 0

        for scalar in fullPreview {
            let byteCount = scalar.utf8.count
            guard contentByteCount + byteCount <= contentLimit else { break }
            content.append(scalar)
            contentByteCount += byteCount
        }

        return String(content) + suffix
    }

    static func preview(_ value: String?, maximumBytes: Int) -> String? {
        value.map { preview($0, maximumBytes: maximumBytes) }
    }

    static func fitsIdentifier(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        return value.utf8.count <= maximumIdentifierBytes
    }
}
