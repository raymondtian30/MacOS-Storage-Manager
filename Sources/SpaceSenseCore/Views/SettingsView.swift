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
        GeometryReader { geo in
            let isCompact = geo.size.width < 720
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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
                .padding(isCompact ? 14 : 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var aiConfigurationSection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Universal AI API Key & Auto Model Detection", systemImage: "key.radiowaves.forward.fill")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    InfoTooltipIcon("Paste a key from Google Gemini (AIza…), OpenAI (sk-…), Anthropic Claude (sk-ant-…), Groq (gsk_…), xAI (xai-…), or OpenRouter (sk-or-…). SpaceSense automatically detects the provider and queries available models. Stored encrypted in the macOS Keychain.")
                    Spacer(minLength: 4)
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
                        .lineLimit(1)
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        apiKeyFieldAndButtons
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SecureField("Paste any API key (Gemini, OpenAI, Anthropic, Groq, xAI, OpenRouter)…", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                        HStack(spacing: 8) {
                            saveAndRemoveKeyButtons
                        }
                    }
                }

                if let apiKeyFeedback {
                    Text(apiKeyFeedback)
                        .font(.caption)
                        .foregroundStyle(SpaceSenseTheme.secondaryAccent)
                }

                Divider()

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Text("Provider: \(appState.detectedAIProvider.rawValue)")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text("Detected Model:")
                            .font(.subheadline)
                        modelPicker
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Provider: \(appState.detectedAIProvider.rawValue)")
                            .font(.subheadline.weight(.medium))
                        HStack {
                            Text("Detected Model:")
                                .font(.subheadline)
                            modelPicker
                        }
                    }
                }

                Toggle("Share full folder paths with AI provider (disable to redact intermediate folder names)", isOn: $appState.shareFullPathsWithAI)
                    .font(.caption)
                    .foregroundStyle(SpaceSenseTheme.slate)
            }
        }
    }

    @ViewBuilder
    private var apiKeyFieldAndButtons: some View {
        SecureField("Paste any API key (Gemini, OpenAI, Anthropic, Groq, xAI, OpenRouter)…", text: $apiKeyInput)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 180)
        saveAndRemoveKeyButtons
    }

    @ViewBuilder
    private var saveAndRemoveKeyButtons: some View {
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
                    .lineLimit(1)
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

    private var modelPicker: some View {
        Picker("Model", selection: $appState.geminiModel) {
            ForEach(appState.detectedAIModels, id: \.self) { model in
                Text(model).tag(model)
            }
        }
        .labelsHidden()
        .frame(minWidth: 150, maxWidth: 240)
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
                    .frame(minWidth: 180, maxWidth: 240)
                    Spacer()
                }

                HStack {
                    Text("Large File Minimum Size Threshold:")
                        .font(.subheadline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Picker("Large File Threshold", selection: $appState.largeFileThresholdMB) {
                        ForEach(AppState.largeFileThresholdOptionsMB, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    Spacer()
                }

                HStack(spacing: 6) {
                    Text("Unused Large File Time Period:")
                        .font(.subheadline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    InfoTooltipIcon("Large files that have not been opened or modified in macOS for at least this time period are automatically added to Delete Hub.")
                    Picker("Unused Period", selection: $appState.unusedFileDaysThreshold) {
                        ForEach(AppState.unusedDaysOptions, id: \.days) { option in
                            Text(option.label).tag(option.days)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 155)
                    Spacer()
                }

                ViewThatFits(in: .horizontal) {
                    HStack {
                        historyRetentionControls
                        Spacer()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        historyRetentionControls
                    }
                }

                Toggle("Include hidden files and dot-directories during scans", isOn: $appState.includeHiddenFiles)
                    .font(.subheadline)

                Toggle("Show macOS notification when a background storage scan completes", isOn: $appState.enableScanNotifications)
                    .font(.subheadline)
            }
        }
    }

    @ViewBuilder
    private var historyRetentionControls: some View {
        HStack(spacing: 8) {
            Text("History Retention:")
                .font(.subheadline)
            Picker("Retention", selection: $appState.historyRetentionDays) {
                Text("30 Days").tag(30)
                Text("90 Days").tag(90)
                Text("180 Days").tag(180)
                Text("365 Days").tag(365)
            }
            .labelsHidden()
            .frame(width: 115)

            Button("Clear Saved History") {
                appState.historyStore.clearAllHistory()
                appState.historySnapshots = []
                appState.growthDeltas = []
                appState.statusBannerMessage = "Storage history database cleared."
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
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
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                        Spacer()
                        Button(role: .destructive) {
                            appState.scanExclusions.removeAll { $0 == path }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove Exclusion")
                    }
                    .padding(.vertical, 1)
                }

                HStack(spacing: 8) {
                    TextField("/path/to/exclude", text: $newExclusionPath)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    Button("Browse…") {
                        if let chosen = appState.bookmarkManager.promptForDirectory() {
                            let normalized = StorageScanner.fastCleanPath(chosen.standardizedFileURL.path)
                            if !appState.scanExclusions.contains(normalized) {
                                appState.scanExclusions.append(normalized)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("Add Exclusion") {
                        let trimmed = newExclusionPath.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        let expanded = (trimmed as NSString).expandingTildeInPath
                        let normalized = StorageScanner.fastCleanPath(URL(fileURLWithPath: expanded).standardizedFileURL.path)
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
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        aboutInfoBlock
                        Spacer(minLength: 8)
                        checkForUpdatesButton
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        aboutInfoBlock
                        checkForUpdatesButton
                    }
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

    private var aboutInfoBlock: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [SpaceSenseTheme.accent, SpaceSenseTheme.secondaryAccent],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 42, height: 42)
                Image(systemName: "internaldrive.fill")
                    .foregroundStyle(.white)
                    .font(.system(size: 19, weight: .bold))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("SpaceSense — AI-Powered macOS Storage Manager")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("Version \(AppState.currentVersion) • Credits: Engineered by Raymond Tian")
                    .font(.caption)
                    .foregroundStyle(SpaceSenseTheme.slate)
                Text("Built natively with Swift, SwiftUI, AppKit, CryptoKit, and SQLite3 for Apple Silicon.")
                    .font(.caption2)
                    .foregroundStyle(SpaceSenseTheme.slate)
            }
        }
    }

    private var checkForUpdatesButton: some View {
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
                    .lineLimit(1)
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(SpaceSenseTheme.accent)
        .disabled(appState.isCheckingForUpdates)
    }
}
