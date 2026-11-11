import SwiftUI

public struct SystemDataView: View {
    @Bindable var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    SectionHeaderBar(
                        title: "System Data Analyzer",
                        subtitle: "Breakdown of measured caches, developer artifacts, estimated snapshots, and protected system folders",
                        icon: NavigationSection.systemData.icon
                    )

                    Button {
                        Task { await appState.refreshSystemData() }
                    } label: {
                        Label(
                            appState.isAnalyzingSystemData ? "Inspecting…" : "Refresh System Data",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SpaceSenseTheme.accent)
                    .disabled(appState.isAnalyzingSystemData)
                }

                if let report = appState.systemDataReport {
                    summaryCards(report: report)
                    itemsListCard(report: report)
                } else {
                    SurfaceCard {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Measuring accessible ~/Library and system storage locations…")
                                .font(.subheadline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(30)
                    }
                }
            }
            .padding(24)
        }
    }

    private func summaryCards(report: SystemDataReport) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4),
            spacing: 14
        ) {
            MetricCardView(
                title: "Measured System Paths",
                value: ByteFormatting.string(report.totalMeasuredBytes),
                subtitle: "Directly measured on disk",
                icon: "checkmark.circle.fill",
                tint: SpaceSenseTheme.secondaryAccent
            )
            MetricCardView(
                title: "Safely Cleanable",
                value: ByteFormatting.string(report.cleanableBytes),
                subtitle: "Caches, logs & DerivedData",
                icon: "trash.slash.fill",
                tint: SpaceSenseTheme.secondaryAccent
            )
            MetricCardView(
                title: "Estimated Unindexed / VM",
                value: ByteFormatting.string(report.estimatedUnindexedSystemBytes),
                subtitle: "APFS snapshots & swap",
                icon: "waveform.path.ecg",
                tint: SpaceSenseTheme.accent,
                tooltip: "macOS System Data includes APFS local snapshots, virtual memory swapfiles, and root-only folders that cannot be enumerated directly by standard user apps."
            )
            MetricCardView(
                title: "Restricted Locations",
                value: "\(report.inaccessiblePathCount)",
                subtitle: "SIP or Full Disk Access",
                icon: "lock.shield.fill",
                tint: SpaceSenseTheme.slate,
                tooltip: "Directories protected by Apple System Integrity Protection (SIP) or requiring Full Disk Access in System Settings."
            )
        }
    }

    private func itemsListCard(report: SystemDataReport) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Inspected System & Library Locations")
                        .font(.headline)
                    InfoTooltipIcon("Measured paths are calculated directly from filesystem metadata. Estimated paths represent volume usage outside accessible folders.")
                    Spacer()
                }

                ForEach(report.items) { item in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(item.category)
                                    .font(.subheadline.weight(.bold))

                                Text(item.measurability.rawValue)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(item.measurability.badgeColor.opacity(0.16), in: Capsule())
                                    .foregroundStyle(item.measurability.badgeColor)

                                Text(item.recommendation.rawValue)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(item.recommendation.color.opacity(0.16), in: Capsule())
                                    .foregroundStyle(item.recommendation.color)

                                if item.recommendation != .recommended {
                                    InfoTooltipIcon("\(item.explanation) Risk: \(item.potentialRisks)")
                                }
                            }

                            Text(item.locationPath)
                                .font(.caption2.monospaced())
                                .foregroundStyle(SpaceSenseTheme.slate)
                                .textSelection(.enabled)

                            Text(item.explanation)
                                .font(.caption)
                                .foregroundStyle(SpaceSenseTheme.slate)
                        }

                        Spacer()

                        Text(item.sizeBytes.map { ByteFormatting.string($0) } ?? "Restricted")
                            .font(.subheadline.monospacedDigit().weight(.bold))
                            .foregroundStyle(item.sizeBytes == nil ? SpaceSenseTheme.slate : .primary)

                        if let url = item.url {
                            Button {
                                appState.revealInFinder(url)
                            } label: {
                                Label("Finder", systemImage: "folder")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(SpaceSenseTheme.slate.opacity(0.06))
                    )
                }
            }
        }
    }
}
