import Foundation

/// Absolute paths as the connected OpenCode server spells them. A macOS or
/// Linux server reports POSIX paths (`/Users/me/app`); a Windows server reports
/// drive paths (`C:\Users\me\app`, also accepted as `C:/Users/me/app`) or UNC
/// paths (`\\server\share\app`). Nothing here consults the phone's file system,
/// so a Windows path is never resolved as a path relative to the iOS root.
nonisolated enum ServerPath {
    nonisolated enum Style: Equatable, Sendable {
        case posix
        case windows
    }

    /// An absolute path split into its root and the segments after it, as written.
    nonisolated struct Components: Equatable, Sendable {
        let style: Style
        /// `/`, a drive root such as `C:\` or `C:/`, or a UNC root such as `\\server\share\`.
        let root: String
        /// The separator the path itself uses; it is reused when rebuilding the path.
        let separator: String
        /// Raw segments after the root. Repeated or trailing separators leave
        /// empty segments, and `.` and `..` are kept.
        let segments: [String]
    }

    static func isAbsolute(_ path: String) -> Bool {
        components(of: path) != nil
    }

    /// Splits an absolute server path. Returns nil for relative paths.
    /// `/C:/...`, a malformed Windows path older clients created, is read as `C:/...`.
    static func components(of path: String) -> Components? {
        var path = Substring(path)
        if path.hasPrefix("/"), hasDrivePrefix(path.dropFirst()) {
            path = path.dropFirst()
        }

        if hasDrivePrefix(path) {
            let rest = path.dropFirst(2)
            let separator = rest.first.map { String($0) } ?? "\\"
            return Components(
                style: .windows,
                root: String(path.prefix(2)) + separator,
                separator: separator,
                segments: splitSegments(rest.dropFirst(), isSeparator: isWindowsSeparator)
            )
        }

        if path.hasPrefix("\\\\") {
            let parts = path.dropFirst(2).split(omittingEmptySubsequences: false, whereSeparator: isWindowsSeparator)
            guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return Components(
                style: .windows,
                root: "\\\\\(parts[0])\\\(parts[1])\\",
                separator: "\\",
                segments: parts.dropFirst(2).map { String($0) }
            )
        }

        if path.hasPrefix("/") {
            return Components(
                style: .posix,
                root: "/",
                separator: "/",
                segments: splitSegments(path.dropFirst(), isSeparator: { $0 == "/" })
            )
        }

        return nil
    }

    /// The path with repeated separators collapsed, `.` and `..` resolved, and
    /// trailing separators removed (a root keeps its own). The path keeps its
    /// separator style and case, so the result can be sent back to the server.
    /// Returns nil for relative paths.
    static func normalized(_ path: String) -> String? {
        guard let parts = components(of: path) else { return nil }
        return rebuilt(parts)
    }

    /// A key for deciding whether two paths name the same location. Windows
    /// paths compare case-insensitively with `\` and `/` treated alike. Keys use
    /// `/` as the separator and are never sent to the server.
    static func comparisonKey(_ path: String) -> String? {
        guard let parts = components(of: path) else { return nil }
        let normalizedPath = rebuilt(parts)
        switch parts.style {
        case .posix:
            return normalizedPath
        case .windows:
            return normalizedPath.replacingOccurrences(of: "\\", with: "/").lowercased()
        }
    }

    static func areEquivalent(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhsKey = lhs.flatMap(comparisonKey(_:)),
              let rhsKey = rhs.flatMap(comparisonKey(_:)) else {
            return false
        }
        return lhsKey == rhsKey
    }

    static func isRoot(_ path: String) -> Bool {
        guard let parts = components(of: path) else { return false }
        return resolvedSegments(parts.segments).isEmpty
    }

    /// The last segment, or the root itself for a root path. Relative paths
    /// fall back to their last `/`-separated segment.
    static func lastComponent(_ path: String) -> String {
        guard let parts = components(of: path) else {
            return path.split(separator: "/").last.map { String($0) } ?? path
        }
        return resolvedSegments(parts.segments).last ?? parts.root
    }

    /// The normalized parent folder, or nil for a root or a relative path.
    static func parent(of path: String) -> String? {
        guard let parts = components(of: path) else { return nil }
        let segments = resolvedSegments(parts.segments)
        guard !segments.isEmpty else { return nil }
        return parts.root + segments.dropLast().joined(separator: parts.separator)
    }

    /// `relativePath` inside `directory`, joined with the directory's own separator.
    static func join(_ directory: String, _ relativePath: String) -> String {
        guard let parts = components(of: directory) else {
            return directory + "/" + relativePath
        }
        let base = rebuilt(parts)
        let isWindows = parts.style == .windows
        let relative = String(relativePath.drop(while: { isWindows ? isWindowsSeparator($0) : $0 == "/" }))
        return base.hasSuffix(parts.separator) ? base + relative : base + parts.separator + relative
    }

    private static func rebuilt(_ parts: Components) -> String {
        parts.root + resolvedSegments(parts.segments).joined(separator: parts.separator)
    }

    private static func resolvedSegments(_ segments: [String]) -> [String] {
        var resolved: [String] = []
        for segment in segments {
            switch segment {
            case "", ".":
                continue
            case "..":
                if !resolved.isEmpty { resolved.removeLast() }
            default:
                resolved.append(segment)
            }
        }
        return resolved
    }

    private static func splitSegments(_ remainder: Substring, isSeparator: (Character) -> Bool) -> [String] {
        guard !remainder.isEmpty else { return [] }
        return remainder.split(omittingEmptySubsequences: false, whereSeparator: isSeparator).map { String($0) }
    }

    /// `C:` alone, or followed by `\` or `/`. `C:name` is drive-relative, not absolute.
    private static func hasDrivePrefix(_ path: Substring) -> Bool {
        var characters = path.makeIterator()
        guard let letter = characters.next(), letter.isASCII, letter.isLetter,
              characters.next() == ":" else {
            return false
        }
        guard let next = characters.next() else { return true }
        return isWindowsSeparator(next)
    }

    private static func isWindowsSeparator(_ character: Character) -> Bool {
        character == "\\" || character == "/"
    }
}
