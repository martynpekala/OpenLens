import Foundation
import Testing
@testable import OpenLens

struct LiveActivityTrackerTests {

    @Test func publishesPermissionPromptAndClearsIt() throws {
        let liveActivity = LiveActivitySpy()
        let tracker = LiveActivityTracker(liveActivity: liveActivity)

        tracker.start(session: nil)
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

        let waiting = try #require(liveActivity.updates.last ?? nil)
        #expect(waiting.kind == .permission)
        #expect(waiting.detail == "bash: npm test")
        #expect(waiting.requestID == "permission-1")
        #expect(waiting.sessionID == "session-1")
        #expect(waiting.quickReplies.isEmpty)

        tracker.clearPendingUserResponse()

        #expect(liveActivity.updates.count == 2)
        #expect(liveActivity.updates.last == .some(nil))
    }

    @Test func offersSingleChoiceQuestionOptionsAsQuickReplies() throws {
        let liveActivity = LiveActivitySpy()
        let tracker = LiveActivityTracker(liveActivity: liveActivity)

        tracker.start(session: nil)
        tracker.setPendingQuestion(
            OCQuestionRequest(
                id: "question-1",
                sessionID: "session-1",
                questions: [
                    OCQuestionInfo(
                        question: "Should the refresh token rotate?",
                        header: "Tokens",
                        options: [
                            OCQuestionOption(label: "Rotate", description: "On every request"),
                            OCQuestionOption(label: "Keep", description: "Until it expires"),
                        ]
                    )
                ]
            )
        )

        let waiting = try #require(liveActivity.updates.last ?? nil)
        #expect(waiting.kind == .question)
        #expect(waiting.detail == "Should the refresh token rotate?")
        #expect(waiting.requestID == "question-1")
        #expect(waiting.quickReplies == [
            .init(label: "Rotate", value: .text("Rotate")),
            .init(label: "Keep", value: .text("Keep")),
        ])
    }

    @Test func questionsThatNeedTheAnswerSheetHaveNoQuickReplies() throws {
        let liveActivity = LiveActivitySpy()
        let tracker = LiveActivityTracker(liveActivity: liveActivity)
        tracker.start(session: nil)

        tracker.setPendingQuestion(
            OCQuestionRequest(
                id: "question-free-text",
                sessionID: "session-1",
                questions: [
                    OCQuestionInfo(question: "Which branch should I compare against?", header: "Comparison", options: [])
                ]
            )
        )
        let freeText = try #require(liveActivity.updates.last ?? nil)
        #expect(freeText.kind == .question)
        #expect(freeText.detail == "Which branch should I compare against?")
        #expect(freeText.quickReplies.isEmpty)

        tracker.setPendingQuestion(
            OCQuestionRequest(
                id: "question-multiple",
                sessionID: "session-1",
                questions: [
                    OCQuestionInfo(
                        question: "Which platforms?",
                        header: "Platforms",
                        options: [
                            OCQuestionOption(label: "iOS", description: ""),
                            OCQuestionOption(label: "macOS", description: ""),
                        ],
                        multiple: true
                    )
                ]
            )
        )
        let multipleChoice = try #require(liveActivity.updates.last ?? nil)
        #expect(multipleChoice.requestID == "question-multiple")
        #expect(multipleChoice.quickReplies.isEmpty)

        let longLabel = String(repeating: "x", count: 65)
        tracker.setPendingQuestion(
            OCQuestionRequest(
                id: "question-long",
                sessionID: "session-1",
                questions: [
                    OCQuestionInfo(
                        question: "Pick one",
                        header: "Choice",
                        options: [
                            OCQuestionOption(label: "Short", description: ""),
                            OCQuestionOption(label: longLabel, description: ""),
                        ]
                    )
                ]
            )
        )
        let longOption = try #require(liveActivity.updates.last ?? nil)
        #expect(longOption.requestID == "question-long")
        #expect(longOption.quickReplies.isEmpty)
    }

    @Test func offersYesAndNoForSingleBooleanForm() throws {
        let liveActivity = LiveActivitySpy()
        let tracker = LiveActivityTracker(liveActivity: liveActivity)
        let form = try JSONDecoder().decode(OCFormRequest.self, from: Data(#"""
        {
          "id": "frm_confirm",
          "sessionID": "ses_confirm",
          "title": "Confirm",
          "fields": [
            {"key": "proceed", "type": "boolean", "required": true, "title": "Deploy to staging?"}
          ]
        }
        """#.utf8))

        tracker.start(session: nil)
        tracker.setPendingForm(form)

        let waiting = try #require(liveActivity.updates.last ?? nil)
        #expect(waiting.kind == .form)
        #expect(waiting.detail == "Deploy to staging?")
        #expect(waiting.requestID == "frm_confirm")
        #expect(waiting.sessionID == "ses_confirm")
        #expect(waiting.fieldKey == "proceed")
        #expect(waiting.quickReplies == [
            .init(label: "No", value: .flag(false)),
            .init(label: "Yes", value: .flag(true)),
        ])
    }

    @Test func offersOptionsForSingleChoiceFormField() throws {
        let liveActivity = LiveActivitySpy()
        let tracker = LiveActivityTracker(liveActivity: liveActivity)
        let form = try JSONDecoder().decode(OCFormRequest.self, from: Data(#"""
        {
          "id": "frm_target",
          "sessionID": "ses_target",
          "title": "Target",
          "fields": [
            {"key": "target", "type": "string", "title": "Build for", "options": [
              {"value": "ios", "label": "iOS"},
              {"value": "macos", "label": "macOS"}
            ]}
          ]
        }
        """#.utf8))

        tracker.start(session: nil)
        tracker.setPendingForm(form)

        let waiting = try #require(liveActivity.updates.last ?? nil)
        #expect(waiting.fieldKey == "target")
        #expect(waiting.quickReplies == [
            .init(label: "iOS", value: .text("ios")),
            .init(label: "macOS", value: .text("macos")),
        ])
    }

    @Test func formsWithSeveralVisibleFieldsHaveNoQuickReplies() throws {
        let liveActivity = LiveActivitySpy()
        let tracker = LiveActivityTracker(liveActivity: liveActivity)
        let form = try JSONDecoder().decode(OCFormRequest.self, from: Data(#"""
        {
          "id": "frm_details",
          "sessionID": "ses_details",
          "title": "Release details",
          "fields": [
            {"key": "confirmed", "type": "boolean", "title": "Ship it?"},
            {"key": "notes", "type": "string", "title": "Notes"}
          ]
        }
        """#.utf8))

        tracker.start(session: nil)
        tracker.setPendingForm(form)

        let waiting = try #require(liveActivity.updates.last ?? nil)
        #expect(waiting.kind == .form)
        #expect(waiting.detail == "Ship it?")
        #expect(waiting.fieldKey == nil)
        #expect(waiting.quickReplies.isEmpty)
    }

    @Test func boundsUntrustedPromptDetailBeforeUpdatingActivityKit() throws {
        let liveActivity = LiveActivitySpy()
        let tracker = LiveActivityTracker(liveActivity: liveActivity)
        let oversized = String(repeating: "x", count: 10_000)

        tracker.start(session: nil)
        tracker.setPendingQuestion(
            OCQuestionRequest(
                id: "question-1",
                sessionID: "session-1",
                questions: [
                    OCQuestionInfo(question: oversized, header: "Header", options: [])
                ]
            )
        )

        let update = try #require(liveActivity.updates.last ?? nil)
        #expect(update.detail.count <= 181)
    }

    @Test func startsActivityForSessionAndCarriesPendingPromptOver() throws {
        let liveActivity = LiveActivitySpy()
        let tracker = LiveActivityTracker(liveActivity: liveActivity)

        tracker.setPendingPermission(
            OCPermissionRequest(
                id: "permission-1",
                sessionID: "ses_1",
                permission: "bash",
                patterns: ["git push"],
                description: "git push",
                title: "bash"
            )
        )
        #expect(liveActivity.updates.isEmpty)

        tracker.start(session: OCSession(id: "ses_1", directory: "/workspace", title: "Auth", time: .init(created: 0, updated: 0)))

        #expect(liveActivity.starts.count == 1)
        #expect(liveActivity.starts.first?.sessionID == "ses_1")
        #expect(liveActivity.starts.first?.directory == "/workspace")
        let carried = try #require(liveActivity.updates.last ?? nil)
        #expect(carried.requestID == "permission-1")
    }

    @Test func skipsUpdatesWhenPromptIsUnchanged() {
        let liveActivity = LiveActivitySpy()
        let tracker = LiveActivityTracker(liveActivity: liveActivity)
        let permission = OCPermissionRequest(
            id: "permission-1",
            sessionID: "session-1",
            permission: "bash",
            patterns: ["npm test"],
            description: "npm test",
            title: "bash"
        )

        tracker.start(session: nil)
        tracker.setPendingPermission(permission)
        tracker.setPendingPermission(permission)
        tracker.clearPendingUserResponse()
        tracker.clearPendingUserResponse()

        #expect(liveActivity.updates.count == 2)
    }

    @Test func endsActivityWithTheTurnOutcome() {
        let liveActivity = LiveActivitySpy()
        let tracker = LiveActivityTracker(liveActivity: liveActivity)

        tracker.start(session: nil)
        tracker.end()
        tracker.end(phase: .failed)

        #expect(liveActivity.endings == [.finished, .failed])
    }

    @Test func sessionsLeftWhileWorkingKeepTheirActivityUntilTheyGoIdle() throws {
        let liveActivity = LiveActivitySpy()
        let tracker = LiveActivityTracker(liveActivity: liveActivity)

        tracker.attach(sessionID: "ses_a")
        tracker.start(session: session("ses_a"))
        tracker.setPendingPermission(permission(id: "per_a", sessionID: "ses_a"))

        // Opening another session must neither end nor clear the first session's activity.
        tracker.detach()
        tracker.clearPendingUserResponse()
        tracker.attach(sessionID: "ses_b")
        tracker.start(session: session("ses_b"))
        tracker.setPendingPermission(permission(id: "per_b", sessionID: "ses_b"))

        #expect(liveActivity.activeSessionIDs == ["ses_a", "ses_b"])
        #expect(liveActivity.updateLog.map(\.sessionID) == ["ses_a", "ses_b"])
        #expect(liveActivity.updateLog.last?.response?.requestID == "per_b")
        #expect(tracker.backgroundSessionIDs == ["ses_a"])

        // The open session's turn ends only its own activity.
        tracker.endActivity(sessionID: "ses_b", phase: .finished)
        #expect(liveActivity.activeSessionIDs == ["ses_a", "ses_b"])

        tracker.endActivity(sessionID: "ses_a", phase: .failed)
        #expect(liveActivity.endLog.map(\.sessionID) == ["ses_a"])
        #expect(liveActivity.endings == [.failed])
        #expect(tracker.backgroundSessionIDs.isEmpty)

        tracker.end()
        #expect(liveActivity.endLog.map(\.sessionID) == ["ses_a", "ses_b"])
        #expect(liveActivity.activeSessionIDs.isEmpty)
    }

    @Test func backgroundSessionWithUnknownOutcomeIsDismissed() {
        let liveActivity = LiveActivitySpy()
        let tracker = LiveActivityTracker(liveActivity: liveActivity)

        tracker.start(session: session("ses_a"))
        tracker.detach()
        tracker.endActivity(sessionID: "ses_a", phase: nil)

        #expect(liveActivity.dismissedSessionIDs == ["ses_a"])
        #expect(liveActivity.endings.isEmpty)
    }

    @Test func detachedTrackerDoesNotEndAnotherSessionsActivity() {
        let liveActivity = LiveActivitySpy()
        let tracker = LiveActivityTracker(liveActivity: liveActivity)

        tracker.start(session: session("ses_a"))
        tracker.detach()
        tracker.end(phase: .failed)
        tracker.dismiss()

        #expect(liveActivity.endings.isEmpty)
        #expect(liveActivity.dismissedSessionIDs.isEmpty)
        #expect(liveActivity.activeSessionIDs == ["ses_a"])
    }

    @Test func reopeningASessionResumesItsActivityAndRefreshesItsPrompt() throws {
        let liveActivity = LiveActivitySpy()
        let tracker = LiveActivityTracker(liveActivity: liveActivity)

        tracker.start(session: session("ses_a"))
        tracker.setPendingPermission(permission(id: "per_a", sessionID: "ses_a"))
        tracker.detach()
        tracker.attach(sessionID: "ses_b")
        tracker.detach()

        // The prompt was answered while the session was not open.
        tracker.attach(sessionID: "ses_a")
        tracker.start(session: session("ses_a"))

        #expect(liveActivity.starts.count == 2)
        #expect(liveActivity.updateLog.last?.sessionID == "ses_a")
        #expect(liveActivity.updateLog.last?.response == nil)
        #expect(tracker.backgroundSessionIDs.isEmpty)

        tracker.end()
        #expect(liveActivity.endLog.map(\.sessionID) == ["ses_a"])
    }

    @Test func boundsSessionTitleForTheActivityPayload() {
        #expect(OpenLensActivityAttributes.boundedSessionTitle(nil) == nil)
        #expect(OpenLensActivityAttributes.boundedSessionTitle("  \n ") == nil)
        #expect(OpenLensActivityAttributes.boundedSessionTitle("  Fix login  ") == "Fix login")
        let long = OpenLensActivityAttributes.boundedSessionTitle(String(repeating: "x", count: 10_000))
        #expect(long?.count == 61)
        #expect(long?.hasSuffix("…") == true)
    }

    private func session(_ id: String) -> OCSession {
        OCSession(id: id, directory: "/workspace", title: id, time: .init(created: 0, updated: 0))
    }

    private func permission(id: String, sessionID: String) -> OCPermissionRequest {
        OCPermissionRequest(
            id: id,
            sessionID: sessionID,
            permission: "bash",
            patterns: ["npm test"],
            description: "npm test",
            title: "bash"
        )
    }
}

/// Keeps one activity per session, like `LiveActivityManager`.
private final class LiveActivitySpy: LiveActivityProviding {
    private(set) var activeSessionIDs: Set<String> = []
    private(set) var starts: [(sessionID: String?, directory: String?)] = []
    private(set) var updateLog: [(sessionID: String?, response: OpenLensActivityAttributes.PendingUserResponse?)] = []
    private(set) var endLog: [(sessionID: String?, phase: OpenLensActivityAttributes.Phase)] = []
    private(set) var dismissedSessionIDs: [String?] = []

    var updates: [OpenLensActivityAttributes.PendingUserResponse?] { updateLog.map(\.response) }
    var endings: [OpenLensActivityAttributes.Phase] { endLog.map(\.phase) }

    func isActive(sessionID: String?) -> Bool {
        activeSessionIDs.contains(sessionID ?? "")
    }

    func startActivity(sessionID: String?, directory: String?, title: String?) {
        starts.append((sessionID, directory))
        activeSessionIDs.insert(sessionID ?? "")
    }

    func update(sessionID: String?, pendingUserResponse: OpenLensActivityAttributes.PendingUserResponse?) {
        updateLog.append((sessionID, pendingUserResponse))
    }

    func endActivity(sessionID: String?, phase: OpenLensActivityAttributes.Phase) {
        endLog.append((sessionID, phase))
        activeSessionIDs.remove(sessionID ?? "")
    }

    func dismissImmediately(sessionID: String?) {
        dismissedSessionIDs.append(sessionID)
        activeSessionIDs.remove(sessionID ?? "")
    }

    func dismissAll() {
        activeSessionIDs.removeAll()
    }

    func previewLiveActivity() {}
}
