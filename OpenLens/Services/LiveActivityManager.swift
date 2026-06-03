import ActivityKit
import Foundation
import os

/// Manages the Live Activity that shows agent thinking steps on the Lock Screen and Dynamic Island.
@MainActor
final class LiveActivityManager: LiveActivityProviding {
    private var currentActivity: Activity<OpenLensActivityAttributes>?
    private var activityStartDate: Date = .init()

    private var pendingContent: ActivityContent<OpenLensActivityAttributes.ContentState>?
    private var debounceTimer: Timer?
    private let debounceInterval: TimeInterval = 0.25
    private var lastUpdateTime: Date = .distantPast
    private var lastStepNumber: Int = 0
    private var lastCostTotal: String?
    private var previewTask: Task<Void, Never>?

    init() {}

    // MARK: - Public API

    /// Start a new Live Activity when the user sends a message.
    func startActivity(agentName: String, userTask: String, subject: String? = nil) {
        if currentActivity != nil {
            endActivity()
        }

        activityStartDate = Date()
        lastStepNumber = 0
        lastCostTotal = nil
        lastUpdateTime = .distantPast

        guard AppPreferences.liveActivitiesEnabled else {
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return
        }

        let attributes = OpenLensActivityAttributes(
            agentName: agentName,
            userTask: userTask
        )
        let initialState = OpenLensActivityAttributes.ContentState(
            subject: subject,
            currentIntent: "Thinking",
            previousIntent: nil,
            secondPreviousIntent: nil,
            intentStartDate: activityStartDate,
            stepNumber: 1,
            costTotal: nil
        )
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

    /// Update the Live Activity with full state.
    /// Uses a throttle+debounce hybrid: fires immediately if enough time has passed
    /// since the last update; otherwise debounces to avoid overwhelming ActivityKit.
    func update(
        subject: String?,
        currentIntent: String,
        currentIntentIcon: String? = nil,
        previousIntent: String?,
        secondPreviousIntent: String?,
        stepNumber: Int,
        costTotal: String?,
        pendingUserResponse: OpenLensActivityAttributes.PendingUserResponse?
    ) {
        guard currentActivity != nil else { return }

        lastStepNumber = stepNumber
        lastCostTotal = costTotal

        let state = OpenLensActivityAttributes.ContentState(
            subject: subject,
            currentIntent: currentIntent,
            currentIntentIcon: currentIntentIcon,
            previousIntent: previousIntent,
            secondPreviousIntent: secondPreviousIntent,
            intentStartDate: activityStartDate,
            stepNumber: stepNumber,
            costTotal: costTotal,
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

    /// End the Live Activity. Shows a brief "Done" state before dismissing.
    func endActivity(completionSummary: String? = nil) {
        previewTask?.cancel()
        previewTask = nil

        // Cancel any pending debounced update — the final state below supersedes it.
        debounceTimer?.invalidate()
        debounceTimer = nil
        pendingContent = nil

        guard let activity = currentActivity else { return }
        currentActivity = nil

        let finalState = OpenLensActivityAttributes.ContentState(
            subject: completionSummary,
            currentIntent: "Complete",
            previousIntent: nil,
            secondPreviousIntent: nil,
            intentStartDate: activityStartDate,
            intentEndDate: .now,
            stepNumber: lastStepNumber,
            costTotal: lastCostTotal
        )
        let content = ActivityContent(state: finalState, staleDate: nil)

        Task {
            await activity.end(content, dismissalPolicy: .after(.now + 8))
        }
    }

    /// Whether a Live Activity is currently active.
    var isActive: Bool {
        currentActivity != nil
    }

    // MARK: - Preview Live Activity

    /// Starts a preview Live Activity that cycles through all sample steps.
    func previewLiveActivity() {
        previewTask?.cancel()

        if currentActivity != nil {
            endActivity()
        }

        guard AppPreferences.liveActivitiesEnabled else {
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return
        }

        let attributes = OpenLensActivityAttributes.preview
        let initialContent = ActivityContent(
            state: OpenLensActivityAttributes.ContentState.step1,
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

            let steps: [OpenLensActivityAttributes.ContentState] = [.step2, .step3, .step4, .step5]
            for step in steps {
                guard let activity = self?.currentActivity, !Task.isCancelled else { return }
                await activity.update(ActivityContent(state: step, staleDate: nil))
                try? await Task.sleep(for: .seconds(3))
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
