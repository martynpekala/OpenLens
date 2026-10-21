import SwiftUI
import UIKit

/// On-demand catch-up for the open session. Opening the sheet only shows a
/// cached result; the model runs when the user taps Generate or Regenerate.
struct SessionSummarySheet: View {
    @Bindable var chatClient: ChatClient
    @Environment(\.dismiss) private var dismiss
    @State private var kind: SessionSummaryKind = .summary

    private var entry: SessionSummaryEntry {
        chatClient.sessionSummaryEntry(for: kind)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker(AppText.sessionSummaryTitle, selection: $kind) {
                        ForEach(SessionSummaryKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                    content

                    if let error = entry.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.appWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(AppText.sessionSummaryDisclaimer)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actions
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.appBackground)
            }
            .background(Color.appBackground)
            .navigationTitle(AppText.sessionSummaryTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.appBackground)
    }

    @ViewBuilder
    private var content: some View {
        if let summary = entry.summary {
            VStack(alignment: .leading, spacing: 8) {
                if chatClient.isSessionSummaryStale(summary) {
                    Label(AppText.sessionSummaryStale, systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.appWarning)
                }
                Text(summary.generatedAt, format: .relative(presentation: .named))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appSecondary)
                DeferredMarkdownTextView(text: summary.text, foregroundColor: Color.appPrimary, usesRetroTypography: false)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(Color.appTertiary.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else if entry.isGenerating {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(AppText.sessionSummaryGenerating)
                    .foregroundStyle(Color.appSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 80)
        } else {
            Text(AppText.sessionSummaryEmptyState)
                .font(.system(size: 14))
                .foregroundStyle(Color.appSecondary)
                .frame(maxWidth: .infinity, minHeight: 80)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if let summary = entry.summary {
                Button {
                    UIPasteboard.general.string = summary.text
                } label: {
                    Label(AppText.copy, systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
            }

            Button {
                let kind = kind
                Task { await chatClient.generateSessionSummary(kind) }
            } label: {
                HStack(spacing: 6) {
                    if entry.isGenerating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(entry.summary == nil ? AppText.sessionSummaryGenerate : AppText.sessionSummaryRegenerate)
                }
                .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .disabled(entry.isGenerating || !chatClient.supportsSessionSummary)
        }
    }
}
