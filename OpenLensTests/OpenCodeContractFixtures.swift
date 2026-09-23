import Foundation

enum OpenCodeContractFixtures {
    static let v1HealthResponse = Data(#"{"healthy":true,"version":"1.5.4-contract"}"#.utf8)

    static let v2InfoResponse = Data(#"""
    {
      "version": "2.0.0-contract",
      "pid": 42,
      "urls": ["http://127.0.0.1:4096"],
      "paths": {"tmp": "/tmp/opencode-contract"}
    }
    """#.utf8)

    static let invalidV2InfoResponse = Data(#"{"version":""}"#.utf8)

    static let v1EventStream = Data(
        (
            "event: server.heartbeat\n"
            + #"data: {"type":"server.heartbeat","properties":{"sequence":7}}"#
            + "\n\n"
        ).utf8
    )

    static let v2EventStream = Data(
        (
            "id: event-contract-1\n"
            + "event: session.updated\n"
            + #"data: {"info":{"id":"session-contract-1","title":"Contract fixture"}}"#
            + "\n\n"
        ).utf8
    )
}
