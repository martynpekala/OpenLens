import Foundation

/// One user-facing change introduced by an OpenLens release.
struct ReleaseHighlight: Identifiable, Equatable {
    let id: String
    let systemImage: String
    let title: String
    let text: String
    /// Fixed in the copy rather than derived from the connected server, so a highlight reads the same everywhere.
    var requiresOpenCodeV2 = false
}

/// The release highlights of one OpenLens marketing version.
struct ReleaseHighlights: Identifiable, Equatable {
    let version: String
    let highlights: [ReleaseHighlight]

    var id: String { version }

    /// Every release that has highlights. Releases without any, such as bug-fix releases, are simply absent.
    static let catalog: [ReleaseHighlights] = [
        ReleaseHighlights(version: "2.2", highlights: [
            ReleaseHighlight(
                id: "2.2.catch-up",
                systemImage: "text.badge.checkmark",
                title: AppText.whatsNew22CatchUpTitle,
                text: AppText.whatsNew22CatchUpText,
                requiresOpenCodeV2: true
            ),
            ReleaseHighlight(
                id: "2.2.subagent-conversations",
                systemImage: "arrow.triangle.branch",
                title: AppText.whatsNew22SubagentTitle,
                text: AppText.whatsNew22SubagentText,
                requiresOpenCodeV2: true
            ),
            ReleaseHighlight(
                id: "2.2.deny-with-reason",
                systemImage: "hand.raised",
                title: AppText.whatsNew22DenyReasonTitle,
                text: AppText.whatsNew22DenyReasonText,
                requiresOpenCodeV2: true
            ),
            ReleaseHighlight(
                id: "2.2.file-search",
                systemImage: "doc.text.magnifyingglass",
                title: AppText.whatsNew22FileSearchTitle,
                text: AppText.whatsNew22FileSearchText,
                requiresOpenCodeV2: true
            ),
            ReleaseHighlight(
                id: "2.2.live-activity-per-session",
                systemImage: "platter.filled.top.iphone",
                title: AppText.whatsNew22LiveActivityTitle,
                text: AppText.whatsNew22LiveActivityText
            ),
        ]),
    ]

    /// Orders dotted marketing versions numerically, so `2.10` follows `2.9`.
    static func isVersion(_ version: String, newerThan other: String) -> Bool {
        version.compare(other, options: .numeric) == .orderedDescending
    }
}
