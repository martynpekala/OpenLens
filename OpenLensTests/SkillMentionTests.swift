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

    @Test func pickingASkillDropsTheTypedQueryForItsChip() {
        #expect(SkillMention.removingActiveQuery(from: "Use @sw") == "Use ")
        #expect(SkillMention.removingActiveQuery(from: "@") == "")
        #expect(SkillMention.removingActiveQuery(from: "Use @swift ") == "Use @swift ")
        #expect(SkillMention.removingActiveQuery(from: "No mention") == "No mention")
    }

    @Test func finishedMentionsOfListedSkillsBecomeChips() {
        let leading = SkillMention.extractingCompletedMentions(from: "@swift fix this", skillIDs: skillIDs)
        #expect(leading.text == "fix this")
        #expect(leading.skillIDs == ["swift"])

        let inline = SkillMention.extractingCompletedMentions(from: "Use @Review and @swift\tnow @review ", skillIDs: skillIDs)
        #expect(inline.text == "Use and now ")
        #expect(inline.skillIDs == ["review", "swift"])

        let newline = SkillMention.extractingCompletedMentions(from: "@swift\nnext", skillIDs: skillIDs)
        #expect(newline.text == "\nnext")
        #expect(newline.skillIDs == ["swift"])
    }

    @Test func unfinishedOrUnknownMentionsStayAsText() {
        for text in ["Use @swift", "@swiftly now", "x@swift now", "@swift, now", "@ now"] {
            let extracted = SkillMention.extractingCompletedMentions(from: text, skillIDs: skillIDs)
            #expect(extracted.text == text)
            #expect(extracted.skillIDs.isEmpty)
        }
        #expect(SkillMention.extractingCompletedMentions(from: "@swift now", skillIDs: []).skillIDs.isEmpty)
    }

    @Test func chipSkillsAreSentAsMentionsThatStillLetCommandsParse() {
        #expect(SkillMention.composing("fix this", mentioning: ["swift", "review"]) == "@swift @review fix this")
        #expect(SkillMention.composing("", mentioning: ["swift"]) == "@swift")
        #expect(SkillMention.composing("plain", mentioning: []) == "plain")
        #expect(SkillMention.composing("/review the diff", mentioning: ["swift"]) == "/review @swift the diff")
        #expect(SkillMention.composing("/review", mentioning: ["swift"]) == "/review @swift")

        let composed = SkillMention.composing("Tidy this screen", mentioning: ["swiftui-ui-patterns"])
        #expect(SkillMention.attachments(in: composed, skillIDs: skillIDs).map(\.id) == ["swiftui-ui-patterns"])

        let restored = SkillMention.extractingCompletedMentions(from: composed, skillIDs: skillIDs)
        #expect(restored.text == "Tidy this screen")
        #expect(restored.skillIDs == ["swiftui-ui-patterns"])
    }
}
