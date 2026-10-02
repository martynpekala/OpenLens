import Foundation
import Testing
@testable import OpenLens

struct ConnectionSetupLinkTests {
    @Test(arguments: [
        "openlens://setup",
        "OpenLens://SETUP",
        "openlens://setup?event=v2-support",
    ])
    func setupLinksOpenConnectionSetupOnly(link: String) throws {
        let url = try #require(URL(string: link))

        #expect(ConnectionSetupLink.matches(url))
        #expect(DeepLinkConnection(from: url) == nil)
        #expect(OpenLensActivityAttributes.sessionID(from: url) == nil)
    }

    @Test(arguments: [
        "openlens://connect?url=192.168.1.50:4096",
        "openlens://session?id=ses_1",
        "openlens://",
        "openlens:///setup",
        "https://setup",
    ])
    func otherLinksAreNotSetupLinks(link: String) throws {
        let url = try #require(URL(string: link))

        #expect(!ConnectionSetupLink.matches(url))
    }
}
