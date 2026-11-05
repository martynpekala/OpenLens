import Foundation

/// Pure merge of every server's inbox. No view code, so it is testable without a host view.

/// A pending item with the server that owns it. Request ids are only unique inside one server,
/// so the server is part of the identity, and replying must go to that server.
struct ServerScoped<Item>: Identifiable {
    let serverID: String
    /// Set only while several servers are saved; the row shows it.
    let tag: ServerTag?
    let item: Item
    private let itemID: String

    init(serverID: String, tag: ServerTag?, item: Item, itemID: String) {
        self.serverID = serverID
        self.tag = tag
        self.item = item
        self.itemID = itemID
    }

    var id: String { "\(serverID)|\(itemID)" }
}

/// What one server returned for the inbox.
struct ServerInboxResult {
    let serverID: String
    let snapshot: InboxSnapshot?
    let failureMessage: String?
}

struct AggregatedInbox {
    var permissions: [ServerScoped<OCPermissionRequest>] = []
    var questions: [ServerScoped<OCQuestionRequest>] = []
    var forms: [ServerScoped<OCFormRequest>] = []
    var warning: String?

    var globalForms: [ServerScoped<OCFormRequest>] { forms.filter { $0.item.isGlobal } }
    var sessionForms: [ServerScoped<OCFormRequest>] { forms.filter { !$0.item.isGlobal } }
    var pendingRequestCount: Int { permissions.count + questions.count + forms.count }
    var isEmpty: Bool { pendingRequestCount == 0 }
}

enum InboxAggregation {
    /// - Parameters:
    ///   - results: One entry per server, in display order.
    ///   - tags: Server identities by id. Used only when `showsServerTags` is set.
    ///   - showsServerTags: `isMultiServerUIEnabled(savedServerCount:)`. When false nothing
    ///     carries a tag and a warning is the server's own, so one saved server reads as it did.
    static func merge(
        results: [ServerInboxResult],
        tags: [String: ServerTag],
        showsServerTags: Bool
    ) -> AggregatedInbox {
        var merged = AggregatedInbox()
        var warnings: [String] = []

        for result in results {
            let tag = showsServerTags ? tags[result.serverID] : nil
            if let snapshot = result.snapshot {
                merged.permissions += snapshot.permissions.map {
                    ServerScoped(serverID: result.serverID, tag: tag, item: $0, itemID: $0.id)
                }
                merged.questions += snapshot.questions.map {
                    ServerScoped(serverID: result.serverID, tag: tag, item: $0, itemID: $0.id)
                }
                merged.forms += snapshot.forms.map {
                    ServerScoped(serverID: result.serverID, tag: tag, item: $0, itemID: "\($0.identity)")
                }
                if let warning = snapshot.warning {
                    warnings.append(prefixed(warning, with: tag))
                }
            } else if let message = result.failureMessage {
                warnings.append(prefixed(message, with: tag))
            }
        }
        merged.warning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        return merged
    }

    private static func prefixed(_ message: String, with tag: ServerTag?) -> String {
        tag.map { "\($0.text): \(message)" } ?? message
    }
}

extension ServerRegistry {
    /// The servers the inbox reads: the active one always (so its failure is reported as it
    /// always was), the others only while connected, because an idle saved server has nothing
    /// pending to show and is not a failing one.
    func inboxSources(activeInbox: InboxService) -> [(id: String, service: InboxService)] {
        let active = activeContext
        var contexts = savedServerContexts
        if contexts.isEmpty { contexts = [active] }
        return contexts
            .filter { $0.id == active.id || $0.connection.isConnected }
            .map { (id: $0.id, service: $0.id == active.id ? activeInbox : $0.inboxService) }
    }

    func serverTags() -> [String: ServerTag] {
        var tags: [String: ServerTag] = [:]
        for context in savedServerContexts {
            guard let profile = profile(for: context) else { continue }
            tags[context.id] = ServerTag(nickname: profile.nickname, serverURL: profile.serverURL)
        }
        return tags
    }

    /// Loads every connected server's inbox and merges it. Throws only when no server answered,
    /// with the first server's own error, which is exactly what one server always threw.
    func loadAggregatedInbox(activeInbox: InboxService) async throws -> AggregatedInbox {
        let sources = inboxSources(activeInbox: activeInbox)
        var results = [ServerInboxResult?](repeating: nil, count: sources.count)
        var firstError: Error?
        await withTaskGroup(of: (Int, InboxSnapshot?, Error?).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask { @MainActor in
                    do { return (index, try await source.service.loadInbox(), nil) }
                    catch { return (index, nil, error) }
                }
            }
            for await (index, snapshot, error) in group {
                results[index] = ServerInboxResult(
                    serverID: sources[index].id,
                    snapshot: snapshot,
                    failureMessage: error?.localizedDescription
                )
                if let error, firstError == nil || index == 0 { firstError = error }
            }
        }
        let ordered = results.compactMap { $0 }
        if let firstError, ordered.allSatisfy({ $0.snapshot == nil }) { throw firstError }
        return InboxAggregation.merge(
            results: ordered,
            tags: serverTags(),
            showsServerTags: isMultiServerUIEnabled(savedServerCount: savedServerContexts.count)
        )
    }
}
