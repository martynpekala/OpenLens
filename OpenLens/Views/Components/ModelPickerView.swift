import SwiftUI

/// Sheet for selecting an AI model from available providers.
struct ModelPickerView: View {
    let selectedProviderID: String
    let selectedModelID: String
    let isLoading: Bool
    let visualMode: ChatVisualMode
    let defaultModelSelection: (providerID: String, modelID: String)?
    var onSelect: (ChatClient.SelectableModel) -> Void
    var onToggleDefault: (ChatClient.SelectableModel) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Pre-computed grouped models — built once in init, O(n) via Dictionary.
    private let groupedModels: [(provider: String, models: [ChatClient.SelectableModel])]

    init(
        models: [ChatClient.SelectableModel],
        selectedProviderID: String,
        selectedModelID: String,
        isLoading: Bool,
        defaultModelSelection: (providerID: String, modelID: String)? = nil,
        visualMode: ChatVisualMode = .standard,
        onSelect: @escaping (ChatClient.SelectableModel) -> Void,
        onToggleDefault: @escaping (ChatClient.SelectableModel) -> Void
    ) {
        self.selectedProviderID = selectedProviderID
        self.selectedModelID = selectedModelID
        self.isLoading = isLoading
        self.defaultModelSelection = defaultModelSelection
        self.visualMode = visualMode
        self.onSelect = onSelect
        self.onToggleDefault = onToggleDefault

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
            modelPickerContent
            .background {
                sheetBackground
                    .ignoresSafeArea()
            }
            .navigationTitle(AppText.model)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text(AppText.done)
                            .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 16, weight: .semibold))
                            .foregroundStyle(primaryTextColor)
                    }
                }
            }
            .toolbarBackground(isRetroChat ? RetroChatStyle.paperWarm : Color.appBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .tint(isRetroChat ? RetroChatStyle.ink : Color.appAccent)
        .presentationBackground(isRetroChat ? RetroChatStyle.screenBottom : Color.appBackground)
    }

    private var isRetroChat: Bool {
        visualMode.isRetro
    }

    private var primaryTextColor: Color {
        isRetroChat ? RetroChatStyle.ink : Color.appPrimary
    }

    private var secondaryTextColor: Color {
        isRetroChat ? RetroChatStyle.secondaryInk : Color.appSecondary
    }

    @ViewBuilder
    private var sheetBackground: some View {
        if isRetroChat {
            RetroChatScreenBackground()
        } else {
            Color.appBackground
        }
    }

    @ViewBuilder
    private var modelPickerContent: some View {
        if isLoading && groupedModels.isEmpty {
            loadingState
        } else if groupedModels.isEmpty {
            emptyState
        } else if isRetroChat {
            retroModelList
        } else {
            standardModelList
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(primaryTextColor)
            Text(AppText.loadingModels)
                .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(secondaryTextColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "cpu")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(secondaryTextColor)
            Text(AppText.emptyModelsTitle)
                .font(isRetroChat ? RetroChatStyle.headerFont : .system(size: 17, weight: .semibold))
                .foregroundStyle(primaryTextColor)
            Text(AppText.emptyModelsSubtitle)
                .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 14))
                .foregroundStyle(secondaryTextColor)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ifRetroPanel(isRetroChat)
        .padding(.horizontal, isRetroChat ? 20 : 0)
    }

    private var standardModelList: some View {
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
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
    }

    private var retroModelList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(groupedModels, id: \.provider) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.provider)
                            .font(RetroChatStyle.smallFont)
                            .foregroundStyle(RetroChatStyle.secondaryInk)
                            .lineLimit(1)
                            .padding(.horizontal, 8)

                        VStack(spacing: 0) {
                            ForEach(Array(group.models.enumerated()), id: \.element.id) { index, model in
                                modelRow(model)

                                if index < group.models.count - 1 {
                                    Rectangle()
                                        .fill(RetroChatStyle.ink.opacity(0.35))
                                        .frame(height: 1)
                                        .padding(.leading, 12)
                                }
                            }
                        }
                        .modifier(RetroChatPanelChrome(fill: RetroChatStyle.paper, cornerRadius: 7, shadowOffset: 3))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
    }

    // MARK: - Model Row

    private func modelRow(_ model: ChatClient.SelectableModel) -> some View {
        let isSelected = model.providerID == selectedProviderID && model.modelID == selectedModelID
        let isDefault = defaultModelSelection?.providerID == model.providerID
            && defaultModelSelection?.modelID == model.modelID

        return HStack(spacing: 12) {
            Button {
                onSelect(model)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.modelName)
                            .font(isRetroChat ? RetroChatStyle.bodyFont : .system(size: 16, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(primaryTextColor)
                            .lineLimit(isRetroChat ? 1 : 2)
                            .minimumScaleFactor(isRetroChat ? 0.75 : 1)

                        Text(model.modelID)
                            .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 12, design: .monospaced))
                            .foregroundStyle(isRetroChat ? RetroChatStyle.mutedInk : Color.appSecondary.opacity(0.72))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)

                        modelMetadata(for: model, isDefault: isDefault)
                    }

                    Spacer()

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(isRetroChat ? RetroChatStyle.blueAccent : .blue)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                onToggleDefault(model)
            } label: {
                Image(systemName: isDefault ? "star.fill" : "star")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isDefault
                        ? (isRetroChat ? RetroChatStyle.magentaAccent : Color.appAccent)
                        : secondaryTextColor)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isDefault ? AppText.clearDefaultModel : AppText.setAsDefaultModel)
        }
        .padding(.horizontal, isRetroChat ? 12 : 0)
        .padding(.vertical, isRetroChat ? 10 : 4)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func modelMetadata(for model: ChatClient.SelectableModel, isDefault: Bool) -> some View {
        if isRetroChat {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if isDefault {
                        capabilityBadge("star.fill", label: AppText.defaultModel, color: RetroChatStyle.magentaAccent)
                    }
                    modelCapabilities(for: model)
                }

                HStack(spacing: 8) {
                    if let costStr = formatCost(model.cost) {
                        Text(costStr)
                    }

                    if let limit = model.limit, let ctx = limit.context, ctx > 0 {
                        Text("\(formatTokenCount(ctx)) ctx")
                    }
                }
                .font(RetroChatStyle.smallFont)
                .foregroundStyle(RetroChatStyle.mutedInk)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
        } else {
            HStack(spacing: 6) {
                if isDefault {
                    capabilityBadge("star.fill", label: AppText.defaultModel, color: Color.appAccent)
                }
                modelCapabilities(for: model)

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
    }

    @ViewBuilder
    private func modelCapabilities(for model: ChatClient.SelectableModel) -> some View {
        if model.reasoning {
            capabilityBadge("brain", label: AppText.reasoning, color: .purple)
        }
        if model.attachment {
            capabilityBadge("paperclip", label: AppText.files, color: .blue)
        }
        if model.toolCall {
            capabilityBadge("wrench", label: AppText.tools, color: .orange)
        }
    }

    private func capabilityBadge(_ icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(label)
                .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 10, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(isRetroChat ? RetroChatStyle.secondaryInk : color)
        .padding(.horizontal, isRetroChat ? 5 : 6)
        .padding(.vertical, 2)
        .background {
            if isRetroChat {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(RetroChatStyle.paperWarm)
            } else {
                Capsule()
                    .fill(color.opacity(0.12))
            }
        }
        .overlay {
            if isRetroChat {
                RetroChatDoubleBorder(cornerRadius: 4, lineWidth: 1)
            }
        }
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
