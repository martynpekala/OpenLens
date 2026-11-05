import ActivityKit
import Foundation
import os

/// Manages the Live Activities that show the agent's progress on the Lock Screen and Dynamic Island.
/// Every session gets its own activity, so several sessions can work at once.
@MainActor
final class LiveActivityManager: LiveActivityProviding {
    /// One running activity and its update throttling.
    private final class Entry {
        let activity: Activity<OpenLensActivityAttributes>
        let startDate: Date
        var pendingContent: ActivityContent<OpenLensActivityAttributes.ContentState>?
        var debounceTimer: Timer?
        var lastUpdateTime: Date = .distantPast

        init(activity: Activity<OpenLensActivityAttributes>, startDate: Date) {
            self.activity = activity
            self.startDate = startDate
        }

        func cancelPendingUpdate() {
            debounceTimer?.invalidate()
            debounceTimer = nil
            pendingContent = nil
        }
    }

    /// Identifies one activity. The same session id on two servers is two activities, and a
    /// session-less turn on each server is its own too.
    struct ActivityKey: Hashable {
        let serverID: String?
        let sessionID: String?

        /// The preview never collides with a real server or session.
        static let preview = ActivityKey(serverID: "\u{0}preview", sessionID: nil)
    }

    /// Running activities.
    private var entries: [ActivityKey: Entry] = [:]
    private let debounceInterval: TimeInterval = 0.25
    private var previewTask: Task<Void, Never>?

    init() {}

    /// Whether an activity already on screen is the earlier turn of this server's session, which
    /// a new turn replaces. Another server's activity for the same session id is not. An activity
    /// with no server was started before multi-server support, by the one server the app then
    /// talked to.
    static func isReplaced(_ attributes: OpenLensActivityAttributes, byTurnOn serverID: String?, sessionID: String?) -> Bool {
        !attributes.isPreview
            && attributes.sessionID == sessionID
            && (attributes.serverID == serverID || attributes.serverID == nil)
    }

    /// Whether dismissing a server's activities also takes this untracked one down.
    static func isDismissed(_ attributes: OpenLensActivityAttributes, withServer serverID: String?) -> Bool {
        attributes.serverID == serverID || attributes.serverID == nil
    }

    private func key(for serverID: String?, _ sessionID: String?) -> ActivityKey {
        ActivityKey(serverID: serverID, sessionID: sessionID)
    }

    // MARK: - Public API

    /// Start a session's Live Activity when a turn begins. A turn that is already shown keeps its
    /// activity and timer, so starting the same running session twice is harmless.
    func startActivity(serverID: String?, sessionID: String?, directory: String?, title: String?) {
        let key = key(for: serverID, sessionID)
        if let entry = entries[key], entry.activity.activityState == .active {
            return
        }
        entries[key]?.cancelPendingUpdate()
        entries[key] = nil

        guard AppPreferences.liveActivitiesEnabled else {
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return
        }

        // The previous turn's activity for this session may still be on screen showing its
        // outcome, or left over from an earlier launch. The new turn replaces it. Another
        // server's activity for the same session id is not this session's, so it stays. An
        // activity with no server was started before multi-server support, by the one server
        // the app then talked to.
        for stale in Activity<OpenLensActivityAttributes>.activities
        where Self.isReplaced(stale.attributes, byTurnOn: serverID, sessionID: sessionID) {
            Task {
                await stale.end(nil, dismissalPolicy: .immediate)
            }
        }

        let startDate = Date()
        let attributes = OpenLensActivityAttributes(
            sessionID: sessionID,
            directory: directory,
            sessionTitle: OpenLensActivityAttributes.boundedSessionTitle(title),
            serverID: serverID
        )
        let initialState = OpenLensActivityAttributes.ContentState(phase: .working, startDate: startDate)
        let content = ActivityContent(state: initialState, staleDate: nil)

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            entries[key] = Entry(activity: activity, startDate: startDate)
        } catch {
            Logger.liveActivity.error("Failed to start Live Activity: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Update the prompt a session's Live Activity shows.
    /// Uses a throttle+debounce hybrid: fires immediately if enough time has passed
    /// since the last update; otherwise debounces to avoid overwhelming ActivityKit.
    func update(serverID: String?, sessionID: String?, pendingUserResponse: OpenLensActivityAttributes.PendingUserResponse?) {
        guard let entry = entries[key(for: serverID, sessionID)] else { return }

        let state = OpenLensActivityAttributes.ContentState(
            phase: .working,
            startDate: entry.startDate,
            pendingUserResponse: pendingUserResponse
        )
        entry.pendingContent = ActivityContent(state: state, staleDate: nil)

        let elapsed = Date().timeIntervalSince(entry.lastUpdateTime)
        entry.debounceTimer?.invalidate()
        entry.debounceTimer = nil
        if elapsed >= debounceInterval {
            // Enough time since last update — flush immediately.
            flushPendingUpdate(of: entry)
        } else {
            // Rapid burst — debounce to fire after the remaining interval.
            let remaining = debounceInterval - elapsed
            let timer = Timer(timeInterval: remaining, repeats: false) { [weak self, weak entry] _ in
                Task { @MainActor [weak self, weak entry] in
                    guard let entry else { return }
                    self?.flushPendingUpdate(of: entry)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            entry.debounceTimer = timer
        }
    }

    private func flushPendingUpdate(of entry: Entry) {
        guard let content = entry.pendingContent else { return }
        entry.pendingContent = nil
        entry.lastUpdateTime = Date()

        let activity = entry.activity
        Task {
            await activity.update(content)
        }
    }

    /// End a session's Live Activity. Shows how the turn ended briefly before dismissing.
    func endActivity(serverID: String?, sessionID: String?, phase: OpenLensActivityAttributes.Phase) {
        finishActivity(key: key(for: serverID, sessionID), phase: phase, dismissalPolicy: .after(.now + 8))
    }

    /// Dismiss a session's Live Activity immediately when its outcome is unknown.
    func dismissImmediately(serverID: String?, sessionID: String?) {
        finishActivity(key: key(for: serverID, sessionID), phase: .stopped, dismissalPolicy: .immediate)
    }

    /// Dismiss one server's Live Activities immediately when its connection is gone. Other
    /// servers' activities keep running. The preview is not tied to a server, so it goes too, and
    /// so do activities with no server: they predate multi-server support.
    func dismissAll(serverID: String?) {
        let keys = entries.keys.filter { $0.serverID == serverID || $0 == .preview }
        endActivities(matching: { Self.isDismissed($0, withServer: serverID) }, keys: Array(keys))
    }

    /// Dismiss every server's Live Activities immediately.
    func dismissEverything() {
        endActivities(matching: { _ in true }, keys: Array(entries.keys))
    }

    private func endActivities(matching belongs: (OpenLensActivityAttributes) -> Bool, keys: [ActivityKey]) {
        let trackedIDs = Set(entries.values.map(\.activity.id))
        if keys.contains(.preview) {
            previewTask?.cancel()
            previewTask = nil
        }

        for key in keys {
            finishActivity(key: key, phase: .stopped, dismissalPolicy: .immediate)
        }

        // Activities left over from an earlier launch, or still showing a finished turn.
        for activity in Activity<OpenLensActivityAttributes>.activities
        where !trackedIDs.contains(activity.id) && belongs(activity.attributes) {
            Task {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private func finishActivity(
        key: ActivityKey,
        phase: OpenLensActivityAttributes.Phase,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) {
        if key == .preview {
            previewTask?.cancel()
            previewTask = nil
        }

        guard let entry = entries.removeValue(forKey: key) else { return }

        // Cancel any pending debounced update — the final state below supersedes it.
        entry.cancelPendingUpdate()

        let finalState = OpenLensActivityAttributes.ContentState(
            phase: phase == .working ? .finished : phase,
            startDate: entry.startDate,
            endDate: .now
        )
        let content = ActivityContent(state: finalState, staleDate: nil)
        let activity = entry.activity

        Task {
            await activity.end(content, dismissalPolicy: dismissalPolicy)
        }
    }

    /// Whether a session's Live Activity is currently active.
    func isActive(serverID: String?, sessionID: String?) -> Bool {
        entries[key(for: serverID, sessionID)] != nil
    }

    // MARK: - Preview Live Activity

    /// Starts a preview Live Activity that cycles through working, both prompts, and finished.
    /// Its buttons clear the prompt locally without calling the server. Session activities keep
    /// running beside it.
    func previewLiveActivity() {
        finishActivity(key: ActivityKey.preview, phase: .finished, dismissalPolicy: .after(.now + 8))

        guard AppPreferences.liveActivitiesEnabled else {
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return
        }

        let attributes = OpenLensActivityAttributes.preview
        let initialContent = ActivityContent(
            state: OpenLensActivityAttributes.ContentState.working,
            staleDate: nil
        )

        let entry: Entry
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: initialContent,
                pushType: nil
            )
            entry = Entry(activity: activity, startDate: OpenLensActivityAttributes.ContentState.startDate)
        } catch {
            Logger.liveActivity.error("Failed to start preview Live Activity: \(error.localizedDescription, privacy: .public)")
            return
        }
        entries[ActivityKey.preview] = entry

        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }

            let steps: [OpenLensActivityAttributes.ContentState] = [.waitingForPermission, .working, .waitingForAnswer, .working]
            for step in steps {
                guard self?.entries[ActivityKey.preview] === entry, !Task.isCancelled else { return }
                await entry.activity.update(ActivityContent(state: step, staleDate: nil))
                try? await Task.sleep(for: .seconds(step.pendingUserResponse == nil ? 3 : 6))
                guard !Task.isCancelled else { return }
            }

            guard self?.entries[ActivityKey.preview] === entry, !Task.isCancelled else { return }
            self?.entries[ActivityKey.preview] = nil

            let finishedState = OpenLensActivityAttributes.ContentState.finished
            await entry.activity.end(
                ActivityContent(state: finishedState, staleDate: nil),
                dismissalPolicy: .after(.now + 8)
            )
        }
    }
}
