import SwiftUI

struct TodoListCardView: View {
    struct Item: Identifiable, Equatable {
        enum Status {
            case pending
            case inProgress
            case completed

            var iconName: String {
                switch self {
                case .pending:
                    return "circle"
                case .inProgress:
                    return "circle.dashed"
                case .completed:
                    return "checkmark.circle.fill"
                }
            }

            var tint: Color {
                switch self {
                case .pending:
                    return Color.appSecondary.opacity(0.7)
                case .inProgress:
                    return .orange
                case .completed:
                    return .green
                }
            }
        }

        let id: String
        let title: String
        let status: Status
    }

    let title: String
    let items: [Item]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "checklist")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.appSecondary.opacity(0.85))

            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: item.status.iconName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(item.status.tint)
                            .frame(width: 14, alignment: .center)

                        Text(item.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.appPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.appSurface)
            )
        }
    }
}

enum TodoListParser {
    static func parse(from text: String) -> [TodoListCardView.Item] {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var items: [TodoListCardView.Item] = []

        for line in lines {
            guard let item = parseLine(line) else { continue }
            items.append(item)
        }

        return items
    }

    static func containsTodoList(in text: String) -> Bool {
        parse(from: text).count >= 2
    }

    private static func parseLine(_ line: String) -> TodoListCardView.Item? {
        guard !line.isEmpty else { return nil }

        let prefixMap: [(String, TodoListCardView.Item.Status)] = [
            ("[ ]", .pending),
            ("[]", .pending),
            ("[•]", .inProgress),
            ("[-]", .inProgress),
            ("[*]", .inProgress),
            ("[x]", .completed),
            ("[X]", .completed)
        ]

        for (prefix, status) in prefixMap where line.hasPrefix(prefix) {
            let title = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return TodoListCardView.Item(id: line, title: title, status: status)
        }

        return nil
    }
}