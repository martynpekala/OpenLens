import SwiftUI

/// Sheet for selecting an AI model from available providers.
struct ModelPickerView: View {
    let selectedProviderID: String
    let selectedModelID: String
    let isLoading: Bool
    let visualMode: ChatVisualMode
    let defaultModelSelection: (providerID: String, modelID: String)?
    let recentModelIDs: [String]
    let quickModelAssignments: [ModelQuickAction: QuickModelAssignment]
    var onSelect: (ChatClient.SelectableModel) -> Void
    var onToggleDefault: (ChatClient.SelectableModel) -> Void
    var onActivateQuickAction: (ModelQuickAction) -> Void
    var onAssignQuickModel: (ModelQuickAction, ChatClient.SelectableModel, String?) -> Void
    var onChangeQuickVariant: (ModelQuickAction, String?) -> Void
    var onClearQuickModel: (ModelQuickAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchQuery = ""
    @State private var activeConfigurationAction: ModelQuickAction?
    @State private var pendingConfigurationModel: ChatClient.SelectableModel?

    /// Pre-computed grouped models — built once in init, O(n) via Dictionary.
    private let allModels: [ChatClient.SelectableModel]
    private let groupedModels: [(provider: String, models: [ChatClient.SelectableModel])]
    private let recentModels: [ChatClient.SelectableModel]

    init(
        models: [ChatClient.SelectableModel],
        selectedProviderID: String,
        selectedModelID: String,
        isLoading: Bool,
        defaultModelSelection: (providerID: String, modelID: String)? = nil,
        recentModelIDs: [String] = [],
        quickModelAssignments: [ModelQuickAction: QuickModelAssignment] = [:],
        visualMode: ChatVisualMode = .standard,
        onSelect: @escaping (ChatClient.SelectableModel) -> Void,
        onToggleDefault: @escaping (ChatClient.SelectableModel) -> Void,
        onActivateQuickAction: @escaping (ModelQuickAction) -> Void,
        onAssignQuickModel: @escaping (ModelQuickAction, ChatClient.SelectableModel, String?) -> Void,
        onChangeQuickVariant: @escaping (ModelQuickAction, String?) -> Void,
        onClearQuickModel: @escaping (ModelQuickAction) -> Void
    ) {
        self.selectedProviderID = selectedProviderID
        self.selectedModelID = selectedModelID
        self.isLoading = isLoading
        self.defaultModelSelection = defaultModelSelection
        self.recentModelIDs = recentModelIDs
        self.quickModelAssignments = quickModelAssignments
        self.visualMode = visualMode
        self.onSelect = onSelect
        self.onToggleDefault = onToggleDefault
        self.onActivateQuickAction = onActivateQuickAction
        self.onAssignQuickModel = onAssignQuickModel
        self.onChangeQuickVariant = onChangeQuickVariant
        self.onClearQuickModel = onClearQuickModel
        self.allModels = models

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
        self.recentModels = Self.orderedRecentModels(from: models, recentModelIDs: recentModelIDs)
    }

    var body: some View {
        NavigationStack {
            pickerBody
                .background {
                    sheetBackground
                        .ignoresSafeArea()
                }
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    Button(role: .close) {
                        dismiss()
                    }
                }
//                .toolbar {
//                    ToolbarItem(placement: .cancellationAction) {
//                        Button {
//                            dismiss()
//                        } label: {
//                            Text(AppText.done)
//                                .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 16, weight: .semibold))
//                                .foregroundStyle(primaryTextColor)
//                        }
//                    }
//                }
                .toolbarBackground(isRetroChat ? RetroChatStyle.paperWarm : Color.appBackground, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
        .tint(isRetroChat ? RetroChatStyle.ink : Color.appAccent)
        .presentationBackground(isRetroChat ? RetroChatStyle.screenBottom : Color.appBackground)
    }

    @ViewBuilder
    private var pickerBody: some View {
        if pendingConfigurationModel != nil {
            quickVariantPicker
        } else {
            modelPickerContent
                .searchable(
                    text: $searchQuery,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text(AppText.searchModels)
                )
        }
    }

    private var navigationTitle: String {
        guard let action = activeConfigurationAction else { return AppText.model }
        if pendingConfigurationModel != nil {
            return AppText.chooseQuickActionVariant(action.title)
        }
        return AppText.chooseQuickActionModel(action.title)
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
        } else if filteredModels.isEmpty {
            noSearchResultsState
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

    private var noSearchResultsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(secondaryTextColor)
            Text(AppText.noMatchingModelsTitle)
                .font(isRetroChat ? RetroChatStyle.headerFont : .system(size: 17, weight: .semibold))
                .foregroundStyle(primaryTextColor)
            Text(AppText.noMatchingModelsSubtitle)
                .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 14))
                .foregroundStyle(secondaryTextColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var standardModelList: some View {
        List {
            if activeConfigurationAction == nil {
                Section {
                    quickActionCards
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 10, trailing: 0))
                        .listRowBackground(Color.clear)
                } header: {
                    quickActionsHeader
                }
            }

            if !filteredRecentModels.isEmpty {
                Section(AppText.recentModels) {
                    ForEach(filteredRecentModels) { model in
                        modelRow(model)
                    }
                }
            }

            ForEach(filteredGroupedModels, id: \.provider) { group in
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
                if activeConfigurationAction == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        quickActionsHeader
                        quickActionCards
                    }
                }

                if !filteredRecentModels.isEmpty {
                    retroModelSection(AppText.recentModels, models: filteredRecentModels)
                }

                ForEach(filteredGroupedModels, id: \.provider) { group in
                    retroModelSection(group.provider, models: group.models)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
    }

    private var quickActionsHeader: some View {
        HStack(spacing: 8) {
            Text(AppText.quickActions)
                .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 13, weight: .semibold))
                .foregroundStyle(secondaryTextColor)

            Spacer()

            quickActionsConfigurationMenu
        }
        .padding(.horizontal, isRetroChat ? 8 : 0)
    }

    private var quickActionCards: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(ModelQuickAction.allCases) { action in
                quickActionCard(action)
            }
        }
    }

    private func quickActionCard(_ action: ModelQuickAction) -> some View {
        let assignment = quickModelAssignments[action]
        let model = assignment.flatMap { assignment in
            allModels.first { $0.id == assignment.id }
        }
        let variantName = assignment.flatMap { assignment in
            model?.variants.first { $0.id == assignment.variant }?.displayName
        } ?? (model == nil ? nil : AppText.thinkingDefault)

        return Button {
            if model == nil {
                beginQuickActionConfiguration(action)
            } else {
                onActivateQuickAction(action)
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Image(systemName: action.systemImage)
                        .font(.system(size: isRetroChat ? 12 : 13, weight: .semibold))

                    Text(action.title)
                        .font(isRetroChat ? RetroChatStyle.bodyFont : .system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .foregroundStyle(primaryTextColor)

                Text(model?.modelName ?? AppText.chooseModel)
                    .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 12, weight: .medium))
                    .foregroundStyle(model == nil ? secondaryTextColor : primaryTextColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                if let variantName {
                    Text(variantName)
                        .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 10, weight: .medium))
                        .foregroundStyle(secondaryTextColor)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.title)
        .accessibilityHint(model == nil ? AppText.chooseQuickActionModel(action.title) : "Activates the assigned model")
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: isRetroChat ? 7 : 14, style: .continuous)
                .fill(isRetroChat ? RetroChatStyle.paper : Color.appSurface)
        }
        .overlay {
            if isRetroChat {
                RetroChatDoubleBorder(cornerRadius: 7, lineWidth: 1)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.appAccent.opacity(0.28), lineWidth: 1)
            }
        }
    }

    private var quickActionsConfigurationMenu: some View {
        Menu {
            ForEach(ModelQuickAction.allCases) { action in
                quickActionConfigurationMenuItem(action)
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isRetroChat ? RetroChatStyle.ink : Color.appAccent)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppText.configureQuickActions)
    }

    private func quickActionConfigurationMenuItem(_ action: ModelQuickAction) -> some View {
        let assignment = quickModelAssignments[action]
        let model = assignment.flatMap { assignment in
            allModels.first { $0.id == assignment.id }
        }

        return Menu {
            quickActionConfigurationActions(action: action, assignment: assignment, model: model)
        } label: {
            Label(action.title, systemImage: action.systemImage)
        }
    }

    @ViewBuilder
    private func quickActionConfigurationActions(
        action: ModelQuickAction,
        assignment: QuickModelAssignment?,
        model: ChatClient.SelectableModel?
    ) -> some View {
        let variants = model.map(reasoningVariants(for:)) ?? []

        Button {
            beginQuickActionConfiguration(action)
        } label: {
            Label(
                assignment == nil
                    ? AppText.chooseQuickActionModel(action.title)
                    : AppText.changeQuickActionModel(action.title),
                systemImage: "cpu"
            )
        }

        if !variants.isEmpty {
            Menu {
                Button {
                    onChangeQuickVariant(action, nil)
                    dismiss()
                } label: {
                    if assignment?.variant == nil {
                        Label(AppText.thinkingDefault, systemImage: "checkmark")
                    } else {
                        Text(AppText.thinkingDefault)
                    }
                }

                ForEach(variants) { variant in
                    Button {
                        onChangeQuickVariant(action, variant.id)
                        dismiss()
                    } label: {
                        if assignment?.variant == variant.id {
                            Label(variant.displayName, systemImage: "checkmark")
                        } else {
                            Text(variant.displayName)
                        }
                    }
                }
            } label: {
                Label(AppText.changeQuickActionVariant(action.title), systemImage: "brain")
            }
        }

        if assignment != nil {
            Button(role: .destructive) {
                onClearQuickModel(action)
            } label: {
                Label(AppText.clearQuickActionModel(action.title), systemImage: "trash")
            }
        }
    }

    private var quickVariantPicker: some View {
        guard let action = activeConfigurationAction,
              let model = pendingConfigurationModel
        else {
            return AnyView(EmptyView())
        }

        let variants = reasoningVariants(for: model)
        let currentAssignment = quickModelAssignments[action]
        let selectedVariant = currentAssignment?.id == model.id
            ? currentAssignment?.variant
            : nil

        return AnyView(
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.modelName)
                            .font(isRetroChat ? RetroChatStyle.headerFont : .system(size: 18, weight: .semibold))
                            .foregroundStyle(primaryTextColor)
                        Text(action.title)
                            .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 13, weight: .medium))
                            .foregroundStyle(secondaryTextColor)
                    }

                    VStack(spacing: 0) {
                        quickVariantRow(
                            name: AppText.thinkingDefault,
                            isSelected: selectedVariant == nil
                        ) {
                            onAssignQuickModel(action, model, nil)
                            dismiss()
                        }

                        ForEach(variants) { variant in
                            if variant.id != variants.first?.id {
                                Rectangle()
                                    .fill(isRetroChat ? RetroChatStyle.ink.opacity(0.25) : Color.appSeparator)
                                    .frame(height: 1)
                            }

                            quickVariantRow(
                                name: variant.displayName,
                                isSelected: selectedVariant == variant.id
                            ) {
                                onAssignQuickModel(action, model, variant.id)
                                dismiss()
                            }
                        }
                    }
                    .background {
                        RoundedRectangle(cornerRadius: isRetroChat ? 7 : 14, style: .continuous)
                            .fill(isRetroChat ? RetroChatStyle.paper : Color.appSurface)
                    }
                    .overlay {
                        if isRetroChat {
                            RetroChatDoubleBorder(cornerRadius: 7, lineWidth: 1)
                        } else {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.appSeparator, lineWidth: 1)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
        )
    }

    private func quickVariantRow(
        name: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(name)
                    .font(isRetroChat ? RetroChatStyle.bodyFont : .system(size: 16, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(primaryTextColor)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(isRetroChat ? RetroChatStyle.blueAccent : Color.appAccent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func reasoningVariants(
        for model: ChatClient.SelectableModel
    ) -> [ChatClient.SelectableModel.SelectableVariant] {
        model.variants.filter { $0.value.isThinkingEffortVariant }
    }

    private func beginQuickActionConfiguration(_ action: ModelQuickAction) {
        activeConfigurationAction = action
        pendingConfigurationModel = nil
        searchQuery = ""
    }

    private func retroModelSection(
        _ title: String,
        models: [ChatClient.SelectableModel]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(RetroChatStyle.smallFont)
                .foregroundStyle(RetroChatStyle.secondaryInk)
                .lineLimit(1)
                .padding(.horizontal, 8)

            VStack(spacing: 0) {
                ForEach(models) { model in
                    modelRow(model)

                    if model.id != models.last?.id {
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

    private var filteredModels: [ChatClient.SelectableModel] {
        Self.models(matching: searchQuery, from: groupedModels.flatMap(\.models))
    }

    private var filteredRecentModels: [ChatClient.SelectableModel] {
        let matchingIDs = Set(filteredModels.map(\.id))
        return recentModels.filter { matchingIDs.contains($0.id) }
    }

    private var filteredGroupedModels: [(provider: String, models: [ChatClient.SelectableModel])] {
        let matchingIDs = Set(filteredModels.map(\.id))
        let recentIDs = Set(recentModels.map(\.id))

        return groupedModels.compactMap { group in
            let models = group.models.filter {
                matchingIDs.contains($0.id) && !recentIDs.contains($0.id)
            }
            guard !models.isEmpty else { return nil }
            return (provider: group.provider, models: models)
        }
    }

    static func models(
        matching query: String,
        from models: [ChatClient.SelectableModel]
    ) -> [ChatClient.SelectableModel] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return models }

        return models.filter { model in
            [model.providerName, model.modelName, model.providerID, model.modelID, model.id]
                .contains { $0.localizedCaseInsensitiveContains(normalizedQuery) }
        }
    }

    static func orderedRecentModels(
        from models: [ChatClient.SelectableModel],
        recentModelIDs: [String]
    ) -> [ChatClient.SelectableModel] {
        var modelsByID: [String: ChatClient.SelectableModel] = [:]
        for model in models {
            modelsByID[model.id] = model
        }

        var seen = Set<String>()
        return recentModelIDs.compactMap { modelID in
            guard seen.insert(modelID).inserted else { return nil }
            return modelsByID[modelID]
        }
    }

    // MARK: - Model Row

    private func modelRow(_ model: ChatClient.SelectableModel) -> some View {
        let isSelected: Bool
        if let action = activeConfigurationAction {
            isSelected = quickModelAssignments[action]?.id == model.id
        } else {
            isSelected = model.providerID == selectedProviderID && model.modelID == selectedModelID
        }
        let isDefault = defaultModelSelection?.providerID == model.providerID
            && defaultModelSelection?.modelID == model.modelID

        return HStack(alignment: .top) {
            Button {
                if let action = activeConfigurationAction {
                    let variants = reasoningVariants(for: model)
                    if variants.isEmpty {
                        onAssignQuickModel(action, model, nil)
                    } else {
                        pendingConfigurationModel = model
                    }
                } else {
                    onSelect(model)
                }
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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
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
        let prices = Self.priceTierLabels(for: model)

        if isRetroChat {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if isDefault {
                        capabilityBadge("star.fill", label: AppText.defaultModel, color: RetroChatStyle.magentaAccent)
                    }
                }
                modelCapabilities(for: model)

                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(prices.enumerated()), id: \.offset) { _, price in
                        Text(price)
                    }

                    if let limit = model.limit, let ctx = limit.context, ctx > 0 {
                        Text("\(Self.formatTokenCount(ctx)) ctx")
                    }
                }
                .font(RetroChatStyle.smallFont)
                .foregroundStyle(RetroChatStyle.mutedInk)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if isDefault {
                    capabilityBadge("star.fill", label: AppText.defaultModel, color: Color.appAccent)
                }
                modelCapabilities(for: model)

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(prices.enumerated()), id: \.offset) { _, price in
                        Text(price)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    if let limit = model.limit, let ctx = limit.context, ctx > 0 {
                        Text("\(Self.formatTokenCount(ctx)) ctx")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func modelCapabilities(for model: ChatClient.SelectableModel) -> some View {
        HStack {
            if model.reasoning {
                capabilityBadge("brain", label: AppText.reasoning, color: .purple)
            }

            if let inputMedia = model.inputMedia {
                ForEach(Self.supportedInputMedia(from: inputMedia), id: \.self) { medium in
                    capabilityBadge(
                        Self.icon(forInputMedium: medium),
                        label: Self.label(forInputMedium: medium),
                        color: Self.color(forInputMedium: medium)
                    )
                }
            } else if model.attachment {
                capabilityBadge("paperclip", label: AppText.files, color: .blue)
            }

            if model.toolCall {
                capabilityBadge("wrench", label: AppText.tools, color: .orange)
            }
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

    @MainActor
    static func inputMediaLabels(for model: ChatClient.SelectableModel) -> [String] {
        if let inputMedia = model.inputMedia {
            return supportedInputMedia(from: inputMedia).map(label(forInputMedium:))
        }

        return model.attachment ? [AppText.files] : []
    }

    @MainActor
    static func priceTierLabels(for model: ChatClient.SelectableModel) -> [String] {
        let costs = model.costTiers.isEmpty
            ? model.cost.map { [$0] } ?? []
            : model.costTiers
        return costs.compactMap(formatCost)
    }

    @MainActor
    private static func supportedInputMedia(from inputMedia: [String]) -> [String] {
        var seen = Set<String>()
        return inputMedia.compactMap { medium in
            let normalized = medium.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, normalized != "text", seen.insert(normalized).inserted else {
                return nil
            }
            return normalized
        }
    }

    @MainActor
    private static func label(forInputMedium medium: String) -> String {
        switch medium {
        case "image": AppText.image
        case "audio": AppText.audio
        case "video": AppText.video
        case "pdf": AppText.pdf
        case "file": AppText.files
        default:
            medium
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    @MainActor
    private static func icon(forInputMedium medium: String) -> String {
        switch medium {
        case "image": "photo"
        case "audio": "waveform"
        case "video": "video"
        case "pdf": "doc.richtext"
        default: "paperclip"
        }
    }

    @MainActor
    private static func color(forInputMedium medium: String) -> Color {
        switch medium {
        case "image": .pink
        case "audio": .indigo
        case "video": .teal
        case "pdf": .red
        default: .blue
        }
    }

    /// Formats reported input/output token prices without filling in any
    /// missing rate. The tier, when present, is the runtime's context boundary.
    @MainActor
    private static func formatCost(_ cost: OCModelCost) -> String? {
        let input = cost.input.map(formatRate)
        let output = cost.output.map(formatRate)
        let cacheRead = cost.cacheRead.map(formatRate)
        let cacheWrite = cost.cacheWrite.map(formatRate)

        let components = [
            input.map { "\($0) in" },
            output.map { "\($0) out" },
            cacheRead.map { "\($0) cache read" },
            cacheWrite.map { "\($0) cache write" },
        ].compactMap(\.self)
        guard !components.isEmpty else { return nil }

        let price: String
        if components.count == 1, let input {
            price = "\(input)/M"
        } else {
            price = "\(components.joined(separator: " / ")) / M"
        }
        guard let tier = cost.tier, tier > 0 else { return price }
        return "\(formatTokenCount(tier)) ctx: \(price)"
    }

    @MainActor
    private static func formatRate(_ rate: Double) -> String {
        if rate == rate.rounded() {
            return String(format: "$%.0f", rate)
        }
        return String(format: "$%.2f", rate)
    }

    /// Format large token counts compactly (e.g. 200000 -> "200K").
    @MainActor
    private static func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return "\(count / 1_000_000)M"
        } else if count >= 1_000 {
            return "\(count / 1_000)K"
        }
        return "\(count)"
    }
}
