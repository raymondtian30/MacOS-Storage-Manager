import SwiftUI

public struct MainWindowView: View {
    @Bindable var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 220, ideal: 235, max: 270)
        } detail: {
            VStack(spacing: 0) {
                if let errorMsg = appState.activeErrorMessage {
                    bannerBar(
                        message: errorMsg,
                        icon: "exclamationmark.triangle.fill",
                        tint: SpaceSenseTheme.danger
                    ) {
                        appState.activeErrorMessage = nil
                    }
                } else if let statusMsg = appState.statusBannerMessage {
                    bannerBar(
                        message: statusMsg,
                        icon: "checkmark.circle.fill",
                        tint: SpaceSenseTheme.secondaryAccent
                    ) {
                        appState.statusBannerMessage = nil
                    }
                }

                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(appState.appearanceMode.colorScheme)
    }

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [SpaceSenseTheme.accent, SpaceSenseTheme.secondaryAccent],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 32, height: 32)
                    Image(systemName: "internaldrive.fill")
                        .foregroundStyle(.white)
                        .font(.system(size: 15, weight: .bold))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("SpaceSense")
                        .font(.headline.weight(.bold))
                    Text("macOS Storage Manager")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            List(NavigationSection.allCases, selection: $appState.selectedSection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .font(.subheadline.weight(.medium))
                    .tag(section)
            }
            .listStyle(.sidebar)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(appState.volumeStats.volumeName)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(ByteFormatting.compactString(appState.volumeStats.availableBytes)) free")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: appState.volumeStats.utilizationPercentage, total: 100)
                    .tint(appState.volumeStats.utilizationPercentage > 85 ? SpaceSenseTheme.danger : SpaceSenseTheme.accent)
                Text("\(ByteFormatting.compactString(appState.volumeStats.usedBytes)) of \(ByteFormatting.compactString(appState.volumeStats.totalBytes)) used")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch appState.selectedSection {
        case .overview:
            OverviewView(appState: appState)
        case .analyzer:
            StorageAnalyzerView(appState: appState)
        case .largeFiles:
            LargeFilesView(appState: appState)
        case .duplicates:
            DuplicateFinderView(appState: appState)
        case .systemData:
            SystemDataView(appState: appState)
        case .smartCleanup:
            SmartCleanupView(appState: appState)
        case .history:
            StorageHistoryView(appState: appState)
        case .aiAssistant:
            AIAssistantView(appState: appState)
        case .settings:
            SettingsView(appState: appState)
        }
    }

    private func bannerBar(
        message: String,
        icon: String,
        tint: Color,
        onDismiss: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(message)
                .font(.caption.weight(.medium))
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(tint.opacity(0.15))
    }
}
