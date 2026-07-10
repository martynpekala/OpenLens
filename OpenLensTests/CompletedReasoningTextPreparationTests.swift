import Testing
@testable import OpenLens

struct CompletedReasoningTextPreparationTests {

    @Test func largeReasoningIsSplitIntoBoundedStableChunks() {
        let text = String(repeating: "reasoning step with a natural break\n", count: 4_000)

        let prepared = CompletedReasoningTextPreparation.prepare(text)

        #expect(prepared.chunks.count > 1)
        #expect(prepared.chunks.allSatisfy {
            $0.text.count <= CompletedReasoningTextPreparation.maximumChunkLength
        })
        #expect(prepared.chunks.map(\.text).joined() == text)
        #expect(prepared.chunks.map(\.id) == Array(prepared.chunks.indices))
    }

    @Test func shortReasoningRemainsOneChunk() {
        let text = "Check the response, then explain the result."

        let prepared = CompletedReasoningTextPreparation.prepare(text)

        #expect(prepared.chunks.count == 1)
        #expect(prepared.chunks.first?.text == text)
        #expect(prepared.chunks.first?.id == 0)
    }
}
