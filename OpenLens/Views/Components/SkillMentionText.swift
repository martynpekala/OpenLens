import SwiftUI

extension EnvironmentValues {
    /// The skills the chat can attach, so sent messages can show their
    /// `@skill` mentions as chips.
    @Entry var chatSkillIDs: [String] = []
}

/// How the chips in a `SkillMentionText` look.
struct SkillChipStyle {
    let color: Color
    let weight: Font.Weight?

    static func standard(_ color: Color) -> SkillChipStyle {
        SkillChipStyle(color: color, weight: .semibold)
    }

    /// The pixel font has a single weight, so retro chips stand out by color alone.
    static let retro = SkillChipStyle(color: RetroChatStyle.blueAccent, weight: nil)
}

/// Message text that draws each `@skill` mention as an inline chip, while the
/// rest keeps wrapping as one paragraph. Font and text color come from the
/// caller; the chip style tints the chips and their labels.
struct SkillMentionText: View {
    let text: String
    let chipStyle: SkillChipStyle

    @Environment(\.chatSkillIDs) private var skillIDs

    var body: some View {
        let mentions = SkillMention.mentionRanges(in: text, skillIDs: skillIDs)
        if mentions.isEmpty {
            Text(text)
        } else {
            textWithChips(for: mentions)
                .textRenderer(
                    SkillChipRenderer(fill: chipStyle.color.opacity(0.2), stroke: chipStyle.color.opacity(0.5))
                )
        }
    }

    private func textWithChips(for mentions: [Range<String.Index>]) -> Text {
        var result = Text(verbatim: "")
        var cursor = text.startIndex
        for mention in mentions {
            let plain = Text(verbatim: String(text[cursor..<mention.lowerBound]))
            result = Text("\(result)\(plain)\(chip(named: text[mention].dropFirst()))")
            cursor = mention.upperBound
        }
        return Text("\(result)\(Text(verbatim: String(text[cursor...])))")
    }

    /// No-break spaces pad the label inside the chip and keep the icon on the
    /// same line as the name. The trailing pad is a little wider because the
    /// symbol brings its own side bearing.
    private func chip(named name: Substring) -> Text {
        let icon = Text(Image(systemName: "wand.and.sparkles")).accessibilityLabel("Skill")
        return Text("\u{00A0}\(icon)\u{2060}\u{00A0}\(Text(verbatim: unbreakable(name)))\u{00A0}\u{202F}")
            .fontWeight(chipStyle.weight)
            .foregroundStyle(chipStyle.color)
            .customAttribute(SkillChipAttribute())
    }

    /// Word joiners after characters such as `-` or `/` stop a line break
    /// from splitting the name across two chips.
    private func unbreakable(_ name: Substring) -> String {
        name.reduce(into: "") { result, character in
            result.append(character)
            if !character.isLetter, !character.isNumber {
                result.append("\u{2060}")
            }
        }
    }
}

private struct SkillChipAttribute: TextAttribute {}

/// Draws a capsule behind each run of chip text on a line, then the line itself.
private struct SkillChipRenderer: TextRenderer {
    let fill: Color
    let stroke: Color

    var displayPadding: EdgeInsets {
        EdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            var chip: CGRect?
            for run in line {
                if run[SkillChipAttribute.self] != nil {
                    let bounds = run.typographicBounds.rect
                    chip = chip?.union(bounds) ?? bounds
                } else if let finished = chip {
                    drawChip(in: finished, context: &context)
                    chip = nil
                }
            }
            if let chip {
                drawChip(in: chip, context: &context)
            }
            context.draw(line)
        }
    }

    private func drawChip(in rect: CGRect, context: inout GraphicsContext) {
        let path = Capsule().path(in: rect)
        context.fill(path, with: .color(fill))
        context.stroke(path, with: .color(stroke), lineWidth: 1)
    }
}
