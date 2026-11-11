import SwiftUI
import AppKit

public struct SettingsView: View {
    @Bindable var appState: AppState
    @State private var apiKeyInput: String = ""
    @State private var newExclusionPath: String = ""
    @State private var apiKeyFeedback: String?

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeaderBar(
                    title: "Settings",
                    subtitle: "AI provider & model auto-detection, Delete Hub thresholds, scan exclusions, and updates",
                    icon: NavigationSection.settings.icon
                )

                aiConfigurationSection
                deleteHubAndScanPreferencesSection
                exclusionsSection
                aboutAndCreditsSection
            }
            .padding(24)
        }
    }

    private var aiConfigurationSection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Universal AI API Key & Auto Model Detection", systemImage: "key.radiowaves.forward.fill")
                        .font(.headline)
                    InfoTooltipIcon("Paste a key from Google Gemini (AIza…), OpenAI (sk-…), Anthropic Claude (sk-ant-…), Groq (gsk_…), xAI (xai-…), or OpenRouter (sk-or-…). SpaceSense automatically detects the provider and queries available models. Stored encrypted in the macOS Keychain.")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(appState.hasConfiguredAPIKey ? SpaceSenseTheme.secondaryAccent : SpaceSenseTheme.slate)
                            .frame(width: 8, height: 8)
                        Text(
                            appState.hasConfiguredAPIKey
                            ? "\(appState.detectedAIProvider.rawValue) Key Active"
                            : "No API Key Configured"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SpaceSenseTheme.slate)
                    }
                }

                HStack(spacing: 10) {
                    SecureField("Paste any API key (Gemini, OpenAI, Anthropic, Groq, xAI, OpenRouter)…", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        let keyToSave = apiKeyInput
                        apiKeyInput = ""
                        appState.saveAPIKey(keyToSave)
                        apiKeyFeedback = "Saved to macOS Keychain & auto-detecting models…"
                    } label: {
                        HStack(spacing: 6) {
                            if appState.isDetectingModels {
                                ProgressView().controlSize(.small)
                            }
                            Text("Save & Auto-Detect")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SpaceSenseTheme.accent)
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if appState.hasConfiguredAPIKey {
                        Button("Remove Key", role: .destructive) {
                            appState.removeAPIKey()
                            apiKeyFeedback = "API key removed from Keychain."
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if let apiKeyFeedback {
                    Text(apiKeyFeedback)
                        .font(.caption)
                        .foregroundStyle(SpaceSenseTheme.secondaryAccent)
                }

                Divider()

                HStack(spacing: 14) {
                    Text("Provider: \(appState.detectedAIProvider.rawValue)")
                        .font(.subheadline.weight(.medium))

                    Spacer()

                    Text("Detected Model:")
                        .font(.subheadline)
                    Picker("Model", selection: $appState.geminiModel) {
                        ForEach(appState.detectedAIModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                }

                Toggle("Share full folder paths with AI provider (disable to redact intermediate folder names)", isOn: $appState.shareFullPathsWithAI)
                    .font(.caption)
                    .foregroundStyle(SpaceSenseTheme.slate)
            }
        }
    }

    private var deleteHubAndScanPreferencesSection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Delete Hub, Scan & Appearance Preferences", systemImage: "slider.horizontal.3")
                    .font(.headline)

                HStack {
                    Text("Appearance:")
                        .font(.subheadline)
                    Picker("Appearance", selection: $appState.appearanceMode) {
                        ForEach(AppAppearanceMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    Spacer()
                }

                HStack {
                    Text("Large File Minimum Size Threshold (250 MB – 1 GB):")
                        .font(.subheadline)
                    Picker("Large File Threshold", selection: $appState.largeFileThresholdMB) {
                        ForEach(AppState.largeFileThresholdOptionsMB, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    Spacer()
                }

                HStack(spacing: 6) {
                    Text("Unused Large File Time Period:")
                        .font(.subheadline)
                    InfoTooltipIcon("Large files that have not been opened or modified in macOS for at least this time period are automatically added to Delete Hub.")
                    Picker("Unused Period", selection: $appState.unusedFileDaysThreshold) {
                        ForEach(AppState.unusedDaysOptions, id: \.days) { option in
                            Text(option.label).tag(option.days)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    Spacer()
                }

                HStack {
                    Text("History Retention Period:")
                        .font(.subheadline)
                    Picker("Retention", selection: $appState.historyRetentionDays) {
                        Text("30 Days").tag(30)
                        Text("90 Days").tag(90)
                        Text("180 Days").tag(180)
                        Text("365 Days").tag(365)
                    }
                    .labelsHidden()
                    .frame(width: 130)

                    Button("Clear Saved History") {
                        appState.historyStore.clearAllHistory()
                        appState.historySnapshots = []
                        appState.growthDeltas = []
                        appState.statusBannerMessage = "Storage history database cleared."
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                }

                Toggle("Include hidden files and dot-directories during scans", isOn: $appState.includeHiddenFiles)
                    .font(.subheadline)

                Toggle("Show macOS notification when a background storage scan completes", isOn: $appState.enableScanNotifications)
                    .font(.subheadline)
            }
        }
    }

    private var exclusionsSection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Label("Scan Exclusions", systemImage: "folder.badge.minus")
                        .font(.headline)
                    InfoTooltipIcon("Excluded paths prevent the scanner from crossing into virtual device mounts (/dev), APFS firmlink loops (/System/Volumes/Data), or external network volumes.")
                    Spacer()
                }

                ForEach(appState.scanExclusions, id: \.self) { path in
                    HStack {
                        Text(path)
                            .font(.caption.monospaced())
                        Spacer()
                        Button(role: .destructive) {
                            appState.scanExclusions.removeAll { $0 == path }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 1)
                }

                HStack(spacing: 8) {
                    TextField("/path/to/exclude", text: $newExclusionPath)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    Button("Add Exclusion") {
                        let trimmed = newExclusionPath.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        let expanded = (trimmed as NSString).expandingTildeInPath
                        let normalized = URL(fileURLWithPath: expanded).standardizedFileURL.path
                        guard !appState.scanExclusions.contains(normalized) else { return }
                        appState.scanExclusions.append(normalized)
                        newExclusionPath = ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var aboutAndCreditsSection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [SpaceSenseTheme.accent, SpaceSenseTheme.secondaryAccent],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 44, height: 44)
                        Image(systemName: "internaldrive.fill")
                            .foregroundStyle(.white)
                            .font(.system(size: 20, weight: .bold))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("SpaceSense — AI-Powered macOS Storage Manager")
                            .font(.headline)
                        Text("Version \(AppState.currentVersion) • Credits: Engineered by Raymond Tian")
                            .font(.caption)
                            .foregroundStyle(SpaceSenseTheme.slate)
                        Text("Built natively with Swift, SwiftUI, AppKit, CryptoKit, and SQLite3 for Apple Silicon.")
                            .font(.caption2)
                            .foregroundStyle(SpaceSenseTheme.slate)
                    }

                    Spacer()

                    Button {
                        Task { await appState.checkForUpdates() }
                    } label: {
                        HStack(spacing: 6) {
                            if appState.isCheckingForUpdates {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text(appState.isCheckingForUpdates ? "Checking…" : "Check for Updates")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SpaceSenseTheme.accent)
                    .disabled(appState.isCheckingForUpdates)
                }

                if let updateMsg = appState.updateStatusMessage {
                    HStack(spacing: 10) {
                        Image(systemName: appState.availableUpdateURL != nil ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(SpaceSenseTheme.secondaryAccent)
                        Text(updateMsg)
                            .font(.caption.weight(.medium))
                        if let releaseURL = appState.availableUpdateURL {
                            Button("Download Release") {
                                NSWorkspace.shared.open(releaseURL)
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }
        }
    }
}
