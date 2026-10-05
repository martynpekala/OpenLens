import Foundation
import Testing
@testable import OpenLens

struct OpenCodeV2FormTests {
    @Test func v2FormsUseTheOwningSessionForRecoveryRepliesAndCancellation() async throws {
        let transport = V2FormTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 200, body: sessionFormListEnvelope()),
            .init(statusCode: 204, body: Data()),
            .init(statusCode: 204, body: Data()),
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "https://opencode.example.com")),
            contextDirectory: "/workspace/OpenLens",
            transport: transport
        )
        _ = try await client.probeCapabilities()

        let forms = try await client.listPendingForms(sessionID: "ses_1")
        try await client.replyToForm(
            sessionID: "ses_1",
            formID: "frm_1",
            answer: [
                "summary": .string("Ship it"),
                "retries": .number(3),
                "approved": .boolean(true),
                "targets": .strings(["ios", "macos"]),
            ]
        )
        try await client.cancelForm(sessionID: "ses_1", formID: "frm_1")

        #expect(forms.map(\.id) == ["frm_1"])
        #expect(forms.first?.sessionID == "ses_1")
        #expect(forms.first?.fields.count == 6)

        let requests = transport.recordedRequests()
        #expect(requests.map(\.path) == [
            "/api/info",
            "/api/session/ses_1/form",
            "/api/session/ses_1/form/frm_1/reply",
            "/api/session/ses_1/form/frm_1",
        ])
        #expect(requests[1...].allSatisfy { $0.queryItems["location[directory]"] == nil })
        #expect(requests[2].method == "POST")
        #expect(requests[3].method == "DELETE")

        let reply = try bodyObject(requests[2])
        let answer = try #require(reply["answer"] as? [String: Any])
        #expect(answer["summary"] as? String == "Ship it")
        #expect(answer["retries"] as? Double == 3)
        #expect(answer["approved"] as? Bool == true)
        #expect(answer["targets"] as? [String] == ["ios", "macos"])
    }

    @Test func v2InboxFormsRecoverSupportedFieldsAndKeepUnknownFieldsExplicitlyUnsupported() async throws {
        let transport = V2FormTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 200, body: locatedFormListEnvelope()),
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "https://opencode.example.com")),
            contextDirectory: "/workspace/OpenLens",
            transport: transport
        )
        _ = try await client.probeCapabilities()

        let forms = try await client.listPendingForms()
        let form = try #require(forms.first)

        #expect(form.id == "frm_inbox")
        #expect(form.sessionID == "ses_inbox")
        #expect(form.fields.map(\.kind) == [.string, .number, .integer, .boolean, .multiselect, .external, .unsupported])
        #expect(form.hasUnsupportedFields)
        #expect(form.fields[5].externalURL?.absoluteString == "https://opencode.ai/docs/forms")
        #expect(form.fields[6].displayTitle == "New server control")

        let request = try #require(transport.recordedRequests().last)
        #expect(request.path == "/api/form")
        #expect(request.queryItems["location[directory]"] == "/workspace/OpenLens")
    }

    @Test func formSafetyRejectsUnsafeReplyTokensButAllowsAnUnknownFieldFallback() throws {
        let form = try JSONDecoder().decode(OCFormRequest.self, from: Data(#"""
        {
          "id": "frm_safe",
          "sessionID": "ses_safe",
          "title": "Safe form",
          "fields": [
            {"key": "known", "type": "string", "title": "Known"},
            {"key": "future", "type": "future", "title": "Future"}
          ]
        }
        """#.utf8))
        #expect(InteractiveFormSafety.sanitize(form)?.hasUnsupportedFields == true)

        let unsafe = try JSONDecoder().decode(OCFormRequest.self, from: Data(#"""
        {
          "id": "frm_unsafe",
          "sessionID": "ses_safe",
          "title": "Unsafe form",
          "fields": [
            {
              "key": "target",
              "type": "multiselect",
              "options": [{"value": "\#(String(repeating: "x", count: 601))", "label": "Too long"}]
            }
          ]
        }
        """#.utf8))
        #expect(InteractiveFormSafety.sanitize(unsafe) == nil)
    }

    @Test func formReplySafetyValidatesBoundsAndSafelyFallsBackForConditionalFields() throws {
        let form = try JSONDecoder().decode(OCFormRequest.self, from: Data(#"""
        {
          "id": "frm_constraints",
          "sessionID": "ses_safe",
          "title": "Constrained form",
          "fields": [
            {"key": "name", "type": "string", "required": true, "minLength": 3, "maxLength": 8},
            {"key": "targets", "type": "multiselect", "minItems": 1, "maxItems": 2, "options": [
              {"value": "ios", "label": "iOS"},
              {"value": "macos", "label": "macOS"}
            ]}
          ]
        }
        """#.utf8))

        #expect(InteractiveFormSafety.accepts(
            answer: ["name": .string("OpenLens"), "targets": .strings(["ios"])],
            for: form
        ))
        #expect(!InteractiveFormSafety.accepts(
            answer: ["name": .string("No"), "targets": .strings(["ios", "macos", "watchos"])],
            for: form
        ))

        let externalLink = try JSONDecoder().decode(OCFormRequest.self, from: Data(#"""
        {
          "id": "frm_external",
          "sessionID": "ses_safe",
          "title": "Linked form",
          "fields": [
            {"key": "name", "type": "string", "required": true},
            {"key": "docs", "type": "external", "required": true, "url": "https://opencode.ai/docs/forms"}
          ]
        }
        """#.utf8))
        #expect(InteractiveFormSafety.accepts(
            answer: ["name": .string("OpenLens"), "docs": .boolean(true)],
            for: externalLink
        ))
        #expect(!InteractiveFormSafety.accepts(
            answer: ["name": .string("OpenLens")],
            for: externalLink
        ))

        let conditional = try JSONDecoder().decode(OCFormRequest.self, from: Data(#"""
        {
          "id": "frm_conditional",
          "sessionID": "ses_safe",
          "title": "Conditional form",
          "fields": [
            {"key": "enabled", "type": "boolean"},
            {"key": "details", "type": "string", "when": [{"key": "enabled", "op": "eq", "value": true}]}
          ]
        }
        """#.utf8))
        #expect(InteractiveFormSafety.sanitize(conditional)?.hasUnsupportedFields == true)
    }

    @Test func formIdentifiersCannotEscapeSessionScopedRoutes() {
        #expect(InteractiveFormSafety.fitsIdentifier("ses_safe-1._~"))
        #expect(!InteractiveFormSafety.fitsIdentifier("../form"))
        #expect(!InteractiveFormSafety.fitsIdentifier("ses/other"))
        #expect(!InteractiveFormSafety.fitsIdentifier("ses?form=other"))
    }

    @Test func requiredFieldsMayStartWithoutDefaultsAndAcceptFalseBooleanValues() throws {
        let form = try JSONDecoder().decode(OCFormRequest.self, from: Data(#"""
        {
          "id": "frm_required",
          "sessionID": "ses_required",
          "title": "Required inputs",
          "fields": [
            {"key": "confirmed", "type": "boolean", "required": true},
            {"key": "targets", "type": "multiselect", "required": true, "options": [
              {"value": "ios", "label": "iOS"}
            ]}
          ]
        }
        """#.utf8))

        #expect(InteractiveFormSafety.sanitize(form) != nil)
        #expect(InteractiveFormSafety.accepts(
            answer: ["confirmed": .boolean(false), "targets": .strings(["ios"])],
            for: form
        ))
    }

    private func sessionFormListEnvelope() -> Data {
        Data(#"""
        {"data":[
          {"id":"frm_1","title":"Release plan","fields":[
            {"key":"summary","type":"string","title":"Summary"},
            {"key":"retries","type":"number","title":"Retries","default":2.5},
            {"key":"build","type":"integer","title":"Build","default":42},
            {"key":"approved","type":"boolean","title":"Approved","default":false},
            {"key":"targets","type":"multiselect","title":"Targets","options":[{"value":"ios","label":"iOS"}]},
            {"key":"docs","type":"external","title":"Read docs","url":"https://opencode.ai/docs/forms"}
          ]}
        ]}
        """#.utf8)
    }

    private func locatedFormListEnvelope() -> Data {
        Data(#"""
        {"location":{"directory":"/workspace/OpenLens"},"data":[
          {"id":"frm_inbox","sessionID":"ses_inbox","title":"Server form","fields":[
            {"key":"name","type":"string","title":"Name"},
            {"key":"ratio","type":"number","title":"Ratio"},
            {"key":"count","type":"integer","title":"Count"},
            {"key":"enabled","type":"boolean","title":"Enabled"},
            {"key":"targets","type":"multiselect","title":"Targets","options":[{"value":"ios","label":"iOS"}]},
            {"key":"docs","type":"external","title":"Docs","url":"https://opencode.ai/docs/forms"},
            {"key":"future","type":"server-control","title":"New server control"}
          ]}
        ]}
        """#.utf8)
    }

    private func bodyObject(_ request: V2FormTransport.RecordedRequest) throws -> [String: Any] {
        let data = try #require(request.body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

nonisolated private final class V2FormTransport: OpenCodeTransport, @unchecked Sendable {
    struct Response: Sendable {
        let statusCode: Int
        let body: Data
    }

    struct RecordedRequest: Sendable {
        let method: String
        let path: String
        let queryItems: [String: String]
        let body: Data?
    }

    private let lock = NSLock()
    private var responses: [Response]
    private var requests: [RecordedRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let queryItems = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .reduce(into: [String: String]()) { result, item in
                if let value = item.value {
                    result[item.name] = value
                }
            }
        let response = try lock.withLock { () throws -> Response in
            requests.append(.init(
                method: request.httpMethod ?? "GET",
                path: url.path,
                queryItems: queryItems,
                body: request.httpBody
            ))
            guard !responses.isEmpty else {
                throw MissingV2FormResponse()
            }
            return responses.removeFirst()
        }

        return (
            response.body,
            HTTPURLResponse(url: url, statusCode: response.statusCode, httpVersion: nil, headerFields: nil)!
        )
    }

    func makeEventStream(
        request: URLRequest,
        deliveryQueue: DispatchQueue,
        callbacks: OpenCodeEventStreamCallbacks
    ) -> any OpenCodeEventStream {
        UnusedV2FormEventStream()
    }

    func recordedRequests() -> [RecordedRequest] {
        lock.withLock { requests }
    }
}

nonisolated private struct MissingV2FormResponse: Error {}

nonisolated private final class UnusedV2FormEventStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}
    func suspend() {}
    func resume() {}
    func cancel() {}
}
