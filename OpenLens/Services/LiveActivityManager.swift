import ActivityKit
import Foundation
import os

/// Manages the Live Activity that shows the agent's progress on the Lock Screen and Dynamic Island.
@MainActor
final class LiveActivityManager: LiveActivityProviding {
    private var currentActivity: Activity<OpenLensActivityAttributes>?
    private var activityStartDate: Date = .init()

    private var pendingContent: ActivityContent<OpenLensActivityAttributes.ContentState>?
    private var debounceTimer: Timer?
    private let debounceInterval: TimeInterval = 0.25
    private var lastUpdateTime: Date = .distantPast
    private var previewTask: Task<Void, Never>?

    init() {}

    // MARK: - Public API

    /// Start a new Live Activity when the user sends a message.
    func startActivity(sessionID: String?, directory: String?) {
        if currentActivity != nil {
            endActivity(phase: .finished)
        }

        activityStartDate = Date()
        lastUpdateTime = .distantPast

        guard AppPreferences.liveActivitiesEnabled else {
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return
        }

        let attributes = OpenLensActivityAttributes(sessionID: sessionID, directory: directory)
        let initialState = OpenLensActivityAttributes.ContentState(phase: .working, startDate: activityStartDate)
        let content = ActivityContent(state: initialState, staleDate: nil)

        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
        } catch {
            Logger.liveActivity.error("Failed to start Live Activity: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Update the prompt the Live Activity shows.
    /// Uses a throttle+debounce hybrid: fires immediately if enough time has passed
    /// since the last update; otherwise debounces to avoid overwhelming ActivityKit.
    func update(pendingUserResponse: OpenLensActivityAttributes.PendingUserResponse?) {
        guard currentActivity != nil else { return }

        let state = OpenLensActivityAttributes.ContentState(
            phase: .working,
            startDate: activityStartDate,
            pendingUserResponse: pendingUserResponse
        )
        pendingContent = ActivityContent(state: state, staleDate: nil)

        let elapsed = Date().timeIntervalSince(lastUpdateTime)
        if elapsed >= debounceInterval {
            // Enough time since last update — flush immediately.
            debounceTimer?.invalidate()
            debounceTimer = nil
            flushPendingUpdate()
        } else {
            // Rapid burst — debounce to fire after the remaining interval.
            debounceTimer?.invalidate()
            let remaining = debounceInterval - elapsed
            let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.flushPendingUpdate()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            debounceTimer = timer
        }
    }

    private func flushPendingUpdate() {
        guard let activity = currentActivity, let content = pendingContent else { return }
        pendingContent = nil
        lastUpdateTime = Date()

        Task {
            await activity.update(content)
        }
    }

    /// End the Live Activity. Shows how the turn ended briefly before dismissing.
    func endActivity(phase: OpenLensActivityAttributes.Phase) {
        finishActivity(phase: phase, dismissalPolicy: .after(.now + 8))
    }

    /// Dismiss the Live Activity immediately when its server context is gone.
    func dismissImmediately() {
        finishActivity(phase: .stopped, dismissalPolicy: .immediate)
    }

    private func finishActivity(
        phase: OpenLensActivityAttributes.Phase,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) {
        previewTask?.cancel()
        previewTask = nil

        // Cancel any pending debounced update — the final state below supersedes it.
        debounceTimer?.invalidate()
        debounceTimer = nil
        pendingContent = nil

        guard let activity = currentActivity else { return }
        currentActivity = nil

        let finalState = OpenLensActivityAttributes.ContentState(
            phase: phase == .working ? .finished : phase,
            startDate: activityStartDate,
            endDate: .now
        )
        let content = ActivityContent(state: finalState, staleDate: nil)

        Task {
            await activity.end(content, dismissalPolicy: dismissalPolicy)
        }
    }

    /// Whether a Live Activity is currently active.
    var isActive: Bool {
        currentActivity != nil
    }

    // MARK: - Preview Live Activity

    /// Starts a preview Live Activity that cycles through working, both prompts, and finished.
    /// Its buttons clear the prompt locally without calling the server.
    func previewLiveActivity() {
        previewTask?.cancel()

        if currentActivity != nil {
            endActivity(phase: .finished)
        }

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

        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: initialContent,
                pushType: nil
            )
        } catch {
            Logger.liveActivity.error("Failed to start preview Live Activity: \(error.localizedDescription, privacy: .public)")
            return
        }

        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }

            let steps: [OpenLensActivityAttributes.ContentState] = [.waitingForPermission, .working, .waitingForAnswer, .working]
            for step in steps {
                guard let activity = self?.currentActivity, !Task.isCancelled else { return }
                await activity.update(ActivityContent(state: step, staleDate: nil))
                try? await Task.sleep(for: .seconds(step.pendingUserResponse == nil ? 3 : 6))
                guard !Task.isCancelled else { return }
            }

            guard let activity = self?.currentActivity, !Task.isCancelled else { return }
            self?.currentActivity = nil

            let finishedState = OpenLensActivityAttributes.ContentState.finished
            await activity.end(
                ActivityContent(state: finishedState, staleDate: nil),
                dismissalPolicy: .after(.now + 8)
            )
        }
    }
}
