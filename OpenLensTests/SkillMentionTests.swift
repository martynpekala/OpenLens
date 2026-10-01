import Testing
@testable import OpenLens

struct SkillMentionTests {
    private let skillIDs = ["swift", "swiftui-ui-patterns", "review"]

    @Test func mentionsAreLocatedInUTF16OffsetsOfTheSubmittedText() throws {
        let text = "👋🏽 Please @swiftui-ui-patterns, then @review."
        let attachments = SkillMention.attachments(in: text, skillIDs: skillIDs)

        #expect(attachments.map(\.id) == ["swiftui-ui-patterns", "review"])
        #expect(attachments.first?.mention?.start == 12)
        #expect(attachments.first?.mention?.end == 32)
        #expect(attachments.first?.mention?.text == "@swiftui-ui-patterns")
        #expect(attachments.last?.mention?.text == "@review")

        let utf16 = Array(text.utf16)
        for attachment in attachments {
            let mention = try #require(attachment.mention)
            #expect(String(decoding: utf16[mention.start..<mention.end], as: UTF16.self) == mention.text)
        }
    }

    @Test func onlyListedSkillsAreAttachedOnceEachMatchingCaseInsensitively() {
        let text = "@Swift and @swift again, plus @unknown and @swiftly"
        let attachments = SkillMention.attachments(in: text, skillIDs: skillIDs)

        #expect(attachments.map(\.id) == ["swift"])
        #expect(attachments.first?.mention?.text == "@Swift")
        #expect(attachments.first?.mention?.start == 0)
    }

    @Test func mentionsMustStartTheTextOrFollowWhitespace() {
        #expect(SkillMention.attachments(in: "mail review@swift.org or x@swift", skillIDs: skillIDs).isEmpty)
        #expect(SkillMention.attachments(in: "First line\n@review", skillIDs: skillIDs).map(\.id) == ["review"])
        #expect(SkillMention.attachments(in: "@review", skillIDs: []).isEmpty)
    }

    @Test func activeQueryIsTheTrailingMentionStillBeingTyped() {
        #expect(SkillMention.activeQuery(in: "@") == "")
        #expect(SkillMention.activeQuery(in: "Use @sw") == "sw")
        #expect(SkillMention.activeQuery(in: "Use @swift ") == nil)
        #expect(SkillMention.activeQuery(in: "me@example") == nil)
        #expect(SkillMention.activeQuery(in: "No mention") == nil)
    }

    @Test func completingReplacesTheTypedQueryWithAnAttachableMention() {
        #expect(SkillMention.completing("Use @sw", with: "swift") == "Use @swift ")
        #expect(SkillMention.completing("@", with: "review") == "@review ")
        #expect(SkillMention.completing("Use", with: "swift") == "Use @swift ")
        #expect(SkillMention.completing("", with: "swift") == "@swift ")

        let completed = SkillMention.completing("Check this with @swiftui", with: "swiftui-ui-patterns") + "please"
        #expect(SkillMention.attachments(in: completed, skillIDs: skillIDs).map(\.id) == ["swiftui-ui-patterns"])
    }
}
