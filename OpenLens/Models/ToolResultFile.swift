import Foundation

/// How a file returned by a tool is shown in its transcript row. Built
/// cheaply from a bounded `OCToolFile`; content is decoded only when shown.
nonisolated struct ToolResultFile: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case image
        case text
        case pdf
        case unsupported
    }

    enum Source: Hashable, Sendable {
        /// Inline content the tool returned.
        case dataURI(String)
        /// A file on the server, read from the session's folder when opened.
        case serverPath(String)
        /// Withheld by `ToolResultFileBudget`.
        case tooLarge
        /// A URI OpenLens can't open, such as a web URL.
        case unavailable
    }

    let id: String
    let title: String
    let mime: String
    let kind: Kind
    let source: Source

    init(file: OCToolFile, id: String) {
        self.id = id
        self.mime = file.mime
        self.kind = Self.kind(forMIME: file.mime)
        self.title = file.name.flatMap { ($0 as NSString).lastPathComponent.nilIfEmpty } ?? file.mime
        self.source = Self.source(for: file.uri)
    }

    /// Why the file can't be opened, or nil for a supported type with content.
    var unavailableError: ToolResultFileError? {
        switch source {
        case .tooLarge: .tooLarge
        case .unavailable: .unavailable
        case .dataURI, .serverPath: kind == .unsupported ? .unsupported : nil
        }
    }

    var isInspectable: Bool { unavailableError == nil }

    /// Why a file can't be opened, shown in place of its preview.
    var unavailableReason: String? {
        guard let error = unavailableError else { return nil }
        return error == .unsupported ? AppText.toolFileUnsupported(mime) : error.errorDescription
    }

    private static func kind(forMIME mime: String) -> Kind {
        let type = mime.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if ["image/png", "image/jpeg", "image/gif", "image/webp", "image/heic", "image/heif", "image/tiff", "image/bmp"]
            .contains(type) {
            return .image
        }
        if type == "application/pdf" { return .pdf }
        if type.hasPrefix("text/")
            || ["application/json", "application/xml", "application/yaml", "application/x-yaml",
                "application/javascript", "application/typescript", "application/x-sh", "application/toml"]
            .contains(type)
            || type.hasSuffix("+json") || type.hasSuffix("+xml") {
            return .text
        }
        return .unsupported
    }

    private static func source(for uri: String?) -> Source {
        guard let uri else { return .tooLarge }
        if uri.prefix(5).lowercased() == "data:" {
            return isBase64DataURI(uri) ? .dataURI(uri) : .unavailable
        }
        guard uri.prefix(5).lowercased() == "file:",
              let components = URLComponents(string: uri),
              (components.host ?? "").isEmpty || components.host == "localhost",
              components.path.hasPrefix("/")
        else {
            return .unavailable
        }
        return .serverPath(components.path)
    }

    private static func isBase64DataURI(_ uri: String) -> Bool {
        guard let comma = uri.firstIndex(of: ",") else { return false }
        return uri[..<comma].lowercased().hasSuffix(";base64")
    }
}

/// Decoded content of an opened tool file.
nonisolated enum ToolResultFileContent: Sendable {
    case image(Data)
    case text(String)
    case pdf(Data)

    /// Largest file opened from the server's session folder.
    static let maximumServerFileBytes = 8 * 1_024 * 1_024

    /// Decodes bytes for `kind`. Text must be UTF-8.
    static func make(kind: ToolResultFile.Kind, data: Data) throws -> ToolResultFileContent {
        switch kind {
        case .image: return .image(data)
        case .pdf: return .pdf(data)
        case .text:
            guard let text = String(data: data, encoding: .utf8) else { throw ToolResultFileError.unreadable }
            return .text(text)
        case .unsupported: throw ToolResultFileError.unsupported
        }
    }

    static func data(fromDataURI uri: String) throws -> Data {
        guard let comma = uri.firstIndex(of: ","),
              let data = Data(base64Encoded: String(uri[uri.index(after: comma)...]), options: .ignoreUnknownCharacters)
        else {
            throw ToolResultFileError.unreadable
        }
        return data
    }
}

nonisolated enum ToolResultFileError: LocalizedError, Equatable, Sendable {
    case tooLarge
    case unsupported
    case unavailable
    case unreadable
    case outsideSession

    var errorDescription: String? {
        switch self {
        case .tooLarge: AppText.toolFileTooLarge
        case .unsupported: AppText.toolFileCannotPreview
        case .unavailable: AppText.toolFileUnavailable
        case .unreadable: AppText.toolFileUnreadable
        case .outsideSession: AppText.toolFileOutsideSession
        }
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}
