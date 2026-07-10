import Testing
@testable import OpenLens

struct AgentActivityTests {

    @MainActor
    @Test func retainsOnlyRecentStepsAcrossManyToolUpdates() {
        let activity = AgentActivity()

        for index in 0..<120 {
            let label = "Tool \(index)"
            _ = activity.recordToolCallIfNeeded(
                label: label,
                detail: "detail \(index)",
                toolCategory: .bash
            )
            if index.isMultiple(of: 2) {
                _ = activity.completeStep(labeled: label)
            }
        }

        #expect(activity.steps.count == AgentActivity.maximumStepCount)
        #expect(activity.steps.first?.label == "Tool 40")
        #expect(activity.steps.last?.label == "Tool 119")
        #expect(activity.completedSteps.map(\.label) == (40..<120)
            .filter { $0.isMultiple(of: 2) }
            .map { "Tool \($0)" })

        _ = activity.completeStep(labeled: "Tool 119")

        #expect(activity.steps.last?.isCompleted == true)
        #expect(activity.completedSteps.count == 41)
        #expect(activity.completedSteps.last?.label == "Tool 119")
    }
}
