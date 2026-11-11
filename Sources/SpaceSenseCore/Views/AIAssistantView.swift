import SwiftUI

public struct AIAssistantView: View {
    @Bindable var appState: AppState
    @State private var inputPrompt: String = ""
    @State private var showingContextInspector: Bool = false

    private let suggestedPrompts: [String] = [
        "Why is my Mac running low on storage?",
        "What is consuming the most space?",
        "Why is System Data so large?",
        "Which files should I investigate?",
        "What can I safely clean?",
        "Which folders have grown the most?",
        "Why is this particular folder so large?"
    ]

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeaderBar(
                    title: "AI Storage Assistant",
                    subtitle: "Powered by Google Gemini (\(appState.geminiModel)) — grounded strictly in your actual scan telemetry",
                    icon: NavigationSection.aiAssistant.icon
                )

                Button {
                    appState.clearAIChat()
                } label: {
                    Label("Clear Chat", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(appState.isAIThinking)

                Button {
                    showingContextInspector = true
                } label: {
                    Label("Inspect Shared Telemetry", systemImage: "eye.trianglebadge.exclamationmark")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }

            if !appState.hasConfiguredAPIKey {
                SurfaceCard(padding: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "key.fill")
                            .foregroundStyle(SpaceSenseTheme.warning)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Gemini API Key Required for AI Responses")
                                .font(.subheadline.weight(.semibold))
                            Text("All other SpaceSense features work offline. Add your Gemini API key in Settings to enable AI storage analysis.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Configure API Key") {
                            appState.selectedSection = .settings
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(SpaceSenseTheme.accent)
                        .controlSize(.small)
                    }
                }
            }

            suggestedPromptsStrip

            SurfaceCard(padding: 14) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(appState.aiMessages) { msg in
                                messageBubble(msg)
                                    .id(msg.id)
                            }
                            if appState.isAIThinking {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Analyzing your storage telemetry with Gemini…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(10)
                            }
                        }
                    }
                    .onChange(of: appState.aiMessages.count) { _, _ in
                        if let lastID = appState.aiMessages.last?.id {
                            withAnimation {
                                proxy.scrollTo(lastID, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            inputBar
        }
        .padding(24)
        .sheet(isPresented: $showingContextInspector) {
            TelemetryPreviewSheet(contextText: appState.currentAIContextSummary())
        }
    }

    private var suggestedPromptsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestedPrompts, id: \.self) { prompt in
                    Button {
                        Task { await appState.sendAIMessage(prompt) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkle")
                                .font(.caption2)
                            Text(prompt)
                                .font(.caption)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(SpaceSenseTheme.accent.opacity(0.14))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.isAIThinking)
                }
            }
        }
    }

    private func messageBubble(_ message: AIMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .assistant {
                Image(systemName: message.isError ? "exclamationmark.triangle.fill" : "brain.head.profile")
                    .foregroundStyle(message.isError ? SpaceSenseTheme.danger : SpaceSenseTheme.accent)
                    .frame(width: 26, height: 26)
                    .background(
                        (message.isError ? SpaceSenseTheme.danger : SpaceSenseTheme.accent).opacity(0.14),
                        in: Circle()
                    )
            } else {
                Spacer()
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(LocalizedStringKey(message.content))
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                message.role == .user
                                ? SpaceSenseTheme.accent.opacity(0.22)
                                : (message.isError ? SpaceSenseTheme.danger.opacity(0.15) : Color.primary.opacity(0.06))
                            )
                    )
                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 680, alignment: message.role == .user ? .trailing : .leading)

            if message.role == .assistant {
                Spacer()
            }
        }
    }

    private var inputBar: some View {
        SurfaceCard(padding: 10) {
            HStack(spacing: 10) {
                TextField("Ask about your storage scan results, System Data, or growing folders…", text: $inputPrompt)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        submitPrompt()
                    }

                Button {
                    submitPrompt()
                } label: {
                    Label("Ask Gemini", systemImage: "paperplane.fill")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(SpaceSenseTheme.accent)
                .disabled(inputPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.isAIThinking)
            }
        }
    }

    private func submitPrompt() {
        let prompt = inputPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        inputPrompt = ""
        Task {
            await appState.sendAIMessage(prompt)
        }
    }
}

private struct TelemetryPreviewSheet: View {
    let contextText: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Privacy & AI Telemetry Inspector")
                        .font(.headline)
                    Text("SpaceSense never uploads your personal file contents. Below is the exact structured metadata summary sent to Gemini when you ask a question.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
            }

            ScrollView {
                Text(contextText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(20)
        .frame(width: 640, height: 480)
    }
}
