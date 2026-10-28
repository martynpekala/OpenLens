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

    /// Running activities keyed by `key(for:)`.
    private var entries: [String: Entry] = [:]
    private let debounceInterval: TimeInterval = 0.25
    private var previewTask: Task<Void, Never>?

    /// The preview never collides with a real session ID.
    private static let previewKey = "\u{0}preview"

    init() {}

    private func key(for sessionID: String?) -> String {
        sessionID ?? ""
    }

    // MARK: - Public API

    /// Start a session's Live Activity when a turn begins. A turn that is already shown keeps its
    /// activity and timer, so starting the same running session twice is harmless.
    func startActivity(sessionID: String?, directory: String?, title: String?) {
        let key = key(for: sessionID)
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
        // outcome, or left over from an earlier launch. The new turn replaces it.
        for stale in Activity<OpenLensActivityAttributes>.activities
        where !stale.attributes.isPreview && stale.attributes.sessionID == sessionID {
            Task {
                await stale.end(nil, dismissalPolicy: .immediate)
            }
        }

        let startDate = Date()
        let attributes = OpenLensActivityAttributes(
            sessionID: sessionID,
            directory: directory,
            sessionTitle: OpenLensActivityAttributes.boundedSessionTitle(title)
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
    func update(sessionID: String?, pendingUserResponse: OpenLensActivityAttributes.PendingUserResponse?) {
        guard let entry = entries[key(for: sessionID)] else { return }

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
    func endActivity(sessionID: String?, phase: OpenLensActivityAttributes.Phase) {
        finishActivity(key: key(for: sessionID), phase: phase, dismissalPolicy: .after(.now + 8))
    }

    /// Dismiss a session's Live Activity immediately when its outcome is unknown.
    func dismissImmediately(sessionID: String?) {
        finishActivity(key: key(for: sessionID), phase: .stopped, dismissalPolicy: .immediate)
    }

    /// Dismiss every Live Activity immediately when their server context is gone.
    func dismissAll() {
        previewTask?.cancel()
        previewTask = nil

        let trackedIDs = Set(entries.values.map(\.activity.id))
        for key in Array(entries.keys) {
            finishActivity(key: key, phase: .stopped, dismissalPolicy: .immediate)
        }

        // Activities left over from an earlier launch, or still showing a finished turn.
        for activity in Activity<OpenLensActivityAttributes>.activities where !trackedIDs.contains(activity.id) {
            Task {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private func finishActivity(
        key: String,
        phase: OpenLensActivityAttributes.Phase,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) {
        if key == Self.previewKey {
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
    func isActive(sessionID: String?) -> Bool {
        entries[key(for: sessionID)] != nil
    }

    // MARK: - Preview Live Activity

    /// Starts a preview Live Activity that cycles through working, both prompts, and finished.
    /// Its buttons clear the prompt locally without calling the server. Session activities keep
    /// running beside it.
    func previewLiveActivity() {
        finishActivity(key: Self.previewKey, phase: .finished, dismissalPolicy: .after(.now + 8))

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
        entries[Self.previewKey] = entry

        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }

            let steps: [OpenLensActivityAttributes.ContentState] = [.waitingForPermission, .working, .waitingForAnswer, .working]
            for step in steps {
                guard self?.entries[Self.previewKey] === entry, !Task.isCancelled else { return }
                await entry.activity.update(ActivityContent(state: step, staleDate: nil))
                try? await Task.sleep(for: .seconds(step.pendingUserResponse == nil ? 3 : 6))
                guard !Task.isCancelled else { return }
            }

            guard self?.entries[Self.previewKey] === entry, !Task.isCancelled else { return }
            self?.entries[Self.previewKey] = nil

            let finishedState = OpenLensActivityAttributes.ContentState.finished
            await entry.activity.end(
                ActivityContent(state: finishedState, staleDate: nil),
                dismissalPolicy: .after(.now + 8)
            )
        }
    }
}
