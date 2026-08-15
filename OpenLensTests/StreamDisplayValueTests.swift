import Testing
@testable import OpenLens

struct StreamDisplayValueTests {

    @Test func boundsDisplayStringsByUTF8Bytes() {
        let oversized = String(repeating: "🙂", count: 1_000)
        let preview = StreamDisplayValue.preview(oversized, maximumBytes: 120)

        #expect(preview.utf8.count <= 120)
        #expect(preview.hasSuffix("…"))
    }

    @Test func acceptsOnlySmallNonemptyIdentifiers() {
        #expect(StreamDisplayValue.fitsIdentifier("session"))
        #expect(!StreamDisplayValue.fitsIdentifier(""))
        #expect(!StreamDisplayValue.fitsIdentifier(nil))
        #expect(!StreamDisplayValue.fitsIdentifier(
            String(repeating: "x", count: StreamDisplayValue.maximumIdentifierBytes + 1)
        ))
    }
}
