import Testing
@testable import OpenLens

struct LiveActivityTrackerTests {

    @Test func keepsCurrentStepWhenPermissionBlocksProgress() throws {
        let liveActivity = LiveActivitySpy()
        let tracker = LiveActivityTracker(liveActivity: liveActivity)

        tracker.start(agentName: "OpenCode", userTask: "Fix auth")
        tracker.pushIntent("Running tests...", icon: "terminal")
        tracker.setPendingPermission(
            OCPermissionRequest(
                id: "permission-1",
                sessionID: "session-1",
                permission: "bash",
                patterns: ["npm test"],
                description: "npm test",
                title: "bash"
            )
        )

        let waitingUpdate = try #require(liveActivity.updates.last)
        #expect(waitingUpdate.stepNumber == 1)
        #expect(waitingUpdate.currentIntent == "Running tests...")
        #expect(waitingUpdate.currentIntentIcon == "terminal")
        #expect(waitingUpdate.pendingUserResponse?.kind == .permission)
        #expect(waitingUpdate.pendingUserResponse?.detail == "bash: npm test")

        tracker.clearPendingUserResponse()

        let clearedUpdate = try #require(liveActivity.updates.last)
        #expect(clearedUpdate.stepNumber == 1)
        #expect(clearedUpdate.pendingUserResponse == nil)
        #expect(clearedUpdate.currentIntent == "Running tests...")
    }

    @Test func publishesQuestionStateEvenBeforeFirstToolStep() throws {
        let liveActivity = LiveActivitySpy()
        let tracker = LiveActivityTracker(liveActivity: liveActivity)

        tracker.start(agentName: "OpenCode", userTask: "Inspect diff")
        tracker.setPendingQuestion(
            OCQuestionRequest(
                id: "question-1",
                sessionID: "session-1",
                questions: [
                    OCQuestionInfo(
                        question: "Which branch should I compare against?",
                        header: "Comparison",
                        options: []
                    )
                ]
            )
        )

        let waitingUpdate = try #require(liveActivity.updates.last)
        #expect(waitingUpdate.stepNumber == 1)
        #expect(waitingUpdate.currentIntent == "Thinking")
        #expect(waitingUpdate.currentIntentIcon == nil)
        #expect(waitingUpdate.pendingUserResponse?.kind == .question)
        #expect(waitingUpdate.pendingUserResponse?.detail == "Which branch should I compare against?")

        tracker.clearPendingUserResponse()

        let clearedUpdate = try #require(liveActivity.updates.last)
        #expect(clearedUpdate.stepNumber == 1)
        #expect(clearedUpdate.pendingUserResponse == nil)
        #expect(clearedUpdate.currentIntent == "Thinking")
    }
}

private final class LiveActivitySpy: LiveActivityProviding {
    struct UpdateSnapshot {
        let subject: String?
        let currentIntent: String
        let currentIntentIcon: String?
        let previousIntent: String?
        let secondPreviousIntent: String?
        let stepNumber: Int
        let costTotal: String?
        let pendingUserResponse: OpenLensActivityAttributes.PendingUserResponse?
    }

    var isActive: Bool = true
    private(set) var updates: [UpdateSnapshot] = []

    func startActivity(agentName: String, userTask: String, subject: String?) {}

    func update(
        subject: String?,
        currentIntent: String,
        currentIntentIcon: String?,
        previousIntent: String?,
        secondPreviousIntent: String?,
        stepNumber: Int,
        costTotal: String?,
        pendingUserResponse: OpenLensActivityAttributes.PendingUserResponse?
    ) {
        updates.append(
            UpdateSnapshot(
                subject: subject,
                currentIntent: currentIntent,
                currentIntentIcon: currentIntentIcon,
                previousIntent: previousIntent,
                secondPreviousIntent: secondPreviousIntent,
                stepNumber: stepNumber,
                costTotal: costTotal,
                pendingUserResponse: pendingUserResponse
            )
        )
    }

    func endActivity(completionSummary: String?) {}

    func previewLiveActivity() {}
}
