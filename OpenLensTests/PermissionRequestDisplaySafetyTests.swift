import Testing
@testable import OpenLens

struct PermissionRequestDisplaySafetyTests {

    @Test func boundsDisplayFieldsAndDisablesAlwaysApprovalForTruncatedScope() {
        let requestID = String(repeating: "request-", count: 20)
        let sessionID = String(repeating: "session-", count: 20)
        let oversizedScopeEntry = String(
            repeating: "scope ",
            count: PermissionRequestDisplaySafety.maximumScopeEntryBytes
        )
        let request = OCPermissionRequest(
            id: requestID,
            sessionID: sessionID,
            permission: String(
                repeating: "permission ",
                count: PermissionRequestDisplaySafety.maximumTitleBytes
            ),
            patterns: (0...PermissionRequestDisplaySafety.maximumScopeEntryCount).map { "rule-\($0)" },
            resources: [oversizedScopeEntry],
            metadata: ["untrusted": AnyCodable(oversizedScopeEntry)],
            always: ["safe-rule"],
            save: ["safe-save"],
            toolRef: OCPermissionToolRef(messageID: oversizedScopeEntry, callID: oversizedScopeEntry),
            input: AnyCodable(["raw": oversizedScopeEntry]),
            description: String(
                repeating: "description ",
                count: PermissionRequestDisplaySafety.maximumDescriptionBytes
            )
        )

        guard let sanitized = PermissionRequestDisplaySafety.sanitize(request) else {
            Issue.record("Expected a permission with an ID to remain presentable")
            return
        }

        #expect(sanitized.id == requestID)
        #expect(sanitized.sessionID == sessionID)
        #expect(sanitized.patterns.count == PermissionRequestDisplaySafety.maximumScopeEntryCount)
        #expect(sanitized.resources.first?.utf8.count ?? 0 <= PermissionRequestDisplaySafety.maximumScopeEntryBytes)
        #expect(sanitized.permission?.utf8.count ?? 0 <= PermissionRequestDisplaySafety.maximumTitleBytes)
        #expect(sanitized.legacyDescription?.utf8.count ?? 0 <= PermissionRequestDisplaySafety.maximumDescriptionBytes)
        #expect(sanitized.metadata == nil)
        #expect(sanitized.input == nil)
        #expect(sanitized.toolRef == nil)
        #expect(sanitized.displayScopeWasTruncated)
        #expect(!PermissionRequestSheet.offersAlwaysApproval(for: sanitized))
        #expect(PermissionRequestSheet.presentationDetents(for: sanitized).count == 2)
    }

    @Test func retainsAlwaysApprovalForACompleteBoundedScope() {
        let request = OCPermissionRequest(
            id: "permission-1",
            sessionID: "session-1",
            action: "bash",
            patterns: ["git status", "git diff"],
            resources: ["repository"],
            always: ["git *"],
            save: ["git status"]
        )

        guard let sanitized = PermissionRequestDisplaySafety.sanitize(request) else {
            Issue.record("Expected a permission with an ID to remain presentable")
            return
        }

        #expect(!sanitized.displayScopeWasTruncated)
        #expect(PermissionRequestSheet.offersAlwaysApproval(for: sanitized))
    }

    @Test func rejectsInvalidIdentifiersInsteadOfRetainingThemInUIState() {
        let oversizedIdentifier = String(
            repeating: "x",
            count: PermissionRequestDisplaySafety.maximumIdentifierBytes + 1
        )

        #expect(
            PermissionRequestDisplaySafety.sanitize(
                OCPermissionRequest(id: "", sessionID: "session-1")
            ) == nil
        )
        #expect(
            PermissionRequestDisplaySafety.sanitize(
                OCPermissionRequest(id: oversizedIdentifier, sessionID: "session-1")
            ) == nil
        )
        #expect(
            PermissionRequestDisplaySafety.sanitize(
                OCPermissionRequest(id: "permission-1", sessionID: oversizedIdentifier)
            ) == nil
        )
    }
}
