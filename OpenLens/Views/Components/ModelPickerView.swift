import SwiftUI

/// Sheet for selecting an AI model from available providers.
struct ModelPickerView: View {
    let selectedProviderID: String
    let selectedModelID: String
    let isLoading: Bool
    var onSelect: (ChatClient.SelectableModel) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Pre-computed grouped models — built once in init, O(n) via Dictionary.
    private let groupedModels: [(provider: String, models: [ChatClient.SelectableModel])]

    init(
        models: [ChatClient.SelectableModel],
        selectedProviderID: String,
        selectedModelID: String,
        isLoading: Bool,
        onSelect: @escaping (ChatClient.SelectableModel) -> Void
    ) {
        self.selectedProviderID = selectedProviderID
        self.selectedModelID = selectedModelID
        self.isLoading = isLoading
        self.onSelect = onSelect

        // O(n) grouping — computed once at init, not on every body evaluation.
        let dict = Dictionary(grouping: models, by: \.providerName)
        var seen: Set<String> = []
        var orderedKeys: [String] = []
        orderedKeys.reserveCapacity(dict.count)
        for model in models {
            if seen.insert(model.providerName).inserted {
                orderedKeys.append(model.providerName)
            }
        }
        self.groupedModels = orderedKeys.compactMap { key in
            guard let group = dict[key] else { return nil }
            return (provider: key, models: group)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && groupedModels.isEmpty {
                    ProgressView(AppText.loadingModels)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if groupedModels.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "cpu")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("No Models Available")
                            .font(.system(size: 17, weight: .semibold))
                        Text("No connected providers with models were found.")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(groupedModels, id: \.provider) { group in
                            Section(group.provider) {
                                ForEach(group.models) { model in
                                    modelRow(model)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(AppText.model)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppText.done) { dismiss() }
                }
            }
        }
    }

    // MARK: - Model Row

    private func modelRow(_ model: ChatClient.SelectableModel) -> some View {
        let isSelected = model.providerID == selectedProviderID && model.modelID == selectedModelID

        return Button {
            onSelect(model)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.modelName)
                        .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)

                    Text(model.modelID)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)

                    HStack(spacing: 6) {
                        if model.reasoning {
                            capabilityBadge("brain", label: AppText.reasoning, color: .purple)
                        }
                        if model.attachment {
                            capabilityBadge("paperclip", label: AppText.files, color: .blue)
                        }
                        if model.toolCall {
                            capabilityBadge("wrench", label: AppText.tools, color: .orange)
                        }

                        if let costStr = formatCost(model.cost) {
                            Spacer().frame(width: 2)
                            Text(costStr)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        if let limit = model.limit, let ctx = limit.context, ctx > 0 {
                            Text("\(formatTokenCount(ctx)) ctx")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.blue)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func capabilityBadge(_ icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(label)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }

    /// Format cost as $/M tokens (input). Returns nil if no cost data.
    private func formatCost(_ cost: OCModelCost?) -> String? {
        guard let cost, let input = cost.input, input > 0 else { return nil }
        if input < 1 {
            return String(format: "$%.2f/M", input)
        }
        return String(format: "$%.0f/M", input)
    }

    /// Format large token counts compactly (e.g. 200000 -> "200K").
    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return "\(count / 1_000_000)M"
        } else if count >= 1_000 {
            return "\(count / 1_000)K"
        }
        return "\(count)"
    }
}
