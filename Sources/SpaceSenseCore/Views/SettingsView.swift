import SwiftUI

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
            VStack(alignment: .leading, spacing: 20) {
                SectionHeaderBar(
                    title: "Settings & Privacy",
                    subtitle: "Configure Keychain API credentials, scan rules, history retention, appearance, and privacy",
                    icon: NavigationSection.settings.icon
                )

                geminiSection
                scanPreferencesSection
                exclusionsSection
                historyAndNotificationsSection
                privacySection
            }
            .padding(24)
        }
    }

    private var geminiSection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Gemini API & Model Configuration", systemImage: "key.radiowaves.forward.fill")
                        .font(.headline)
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(appState.hasConfiguredAPIKey ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(appState.hasConfiguredAPIKey ? "Saved in macOS Keychain" : "No API Key Configured")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Your Gemini API key is stored exclusively in the macOS Keychain (`com.spacesense.macos.credentials`) and is never logged or written to plaintext files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    SecureField("Paste Gemini API Key (AIza…)", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)

                    Button("Save to Keychain") {
                        appState.saveAPIKey(apiKeyInput)
                        apiKeyInput = ""
                        apiKeyFeedback = "API key saved securely to macOS Keychain."
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

                HStack {
                    Text("Gemini Model:")
                        .font(.subheadline.weight(.medium))
                    Picker("Model", selection: $appState.geminiModel) {
                        ForEach(GeminiService.availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    Spacer()
                }
            }
        }
    }

    private var scanPreferencesSection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Scan Preferences & Appearance", systemImage: "slider.horizontal.3")
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
                    Text("Large File Minimum Size Threshold:")
                        .font(.subheadline)
                    Picker("Threshold", selection: $appState.largeFileThresholdMB) {
                        Text("10 MB").tag(10.0)
                        Text("25 MB").tag(25.0)
                        Text("50 MB (Default)").tag(50.0)
                        Text("100 MB").tag(100.0)
                        Text("500 MB").tag(500.0)
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    Spacer()
                }

                Toggle("Include hidden files and dot-directories during scans", isOn: $appState.includeHiddenFiles)
                    .font(.subheadline)

                HStack {
                    Button("Clear Cached Scan Metadata") {
                        Task {
                            await appState.scanner.clearCache()
                            await appState.duplicateDetector.clearCache()
                            appState.statusBannerMessage = "Scanner and SHA-256 hash caches cleared."
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                }
            }
        }
    }

    private var exclusionsSection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Scan Exclusions", systemImage: "folder.badge.minus")
                    .font(.headline)
                Text("Directories listed below are skipped during recursive filesystem scans to prevent virtual mount loops and redundant volume scans.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
                    .padding(.vertical, 2)
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

    private var historyAndNotificationsSection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Storage History & Notifications", systemImage: "clock.arrow.circlepath")
                    .font(.headline)

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
                    .frame(width: 150)

                    Button("Clear All Saved History", role: .destructive) {
                        appState.historyStore.clearAllHistory()
                        appState.historySnapshots = []
                        appState.growthDeltas = []
                        appState.statusBannerMessage = "Storage history database cleared."
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                }

                Toggle("Show macOS notification when a background storage scan completes", isOn: $appState.enableScanNotifications)
                    .font(.subheadline)
            }
        }
    }

    private var privacySection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Privacy & Data Safety Guarantees", systemImage: "hand.raised.shield.fill")
                    .font(.headline)

                Toggle("Share full folder paths with Gemini AI (disable to redact intermediate folder names)", isOn: $appState.shareFullPathsWithAI)
                    .font(.subheadline)

                VStack(alignment: .leading, spacing: 4) {
                    Text("• All filesystem scanning, folder size calculation, and SHA-256 duplicate hashing happen 100% locally on your Mac.")
                    Text("• SpaceSense never uploads your files or reads personal document contents for AI queries.")
                    Text("• Cleanup actions move selected files to your macOS Trash and never bypass Trash with permanent deletion.")
                    Text("• Protected macOS System Integrity Protection (SIP) paths (/System, /usr, /bin, /sbin) are strictly read-only.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}
