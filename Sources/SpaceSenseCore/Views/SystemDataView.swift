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
                        subtitle: "Transparent breakdown of measured caches, developer artifacts, estimated snapshots, and protected system folders",
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

                transparencyNoticeCard

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

    private var transparencyNoticeCard: some View {
        SurfaceCard(padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "info.circle.fill")
                    .font(.title3)
                    .foregroundStyle(SpaceSenseTheme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Understanding macOS System Data")
                        .font(.subheadline.weight(.semibold))
                    Text("macOS System Data is not a single folder. It spans user library caches, developer build artifacts, APFS local snapshots, virtual memory swap, and SIP-protected OS components. SpaceSense clearly distinguishes **Directly Measured** paths from **Estimated** volume overhead and **Permission-Restricted** directories, and never modifies protected macOS system files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
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
                tint: .green
            )
            MetricCardView(
                title: "Safely Cleanable",
                value: ByteFormatting.string(report.cleanableBytes),
                subtitle: "Caches, logs & DerivedData",
                icon: "sparkles",
                tint: SpaceSenseTheme.secondaryAccent
            )
            MetricCardView(
                title: "Estimated Unindexed / VM",
                value: ByteFormatting.string(report.estimatedUnindexedSystemBytes),
                subtitle: "APFS snapshots & unscanned paths",
                icon: "waveform.path.ecg",
                tint: .orange
            )
            MetricCardView(
                title: "Restricted Locations",
                value: "\(report.inaccessiblePathCount)",
                subtitle: "Protected by SIP or permissions",
                icon: "lock.shield.fill",
                tint: .secondary
            )
        }
    }

    private func itemsListCard(report: SystemDataReport) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Inspected System & Library Locations")
                    .font(.headline)

                ForEach(report.items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text(item.category)
                                        .font(.subheadline.weight(.bold))

                                    Text(item.measurability.rawValue)
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(item.measurability.badgeColor.opacity(0.18), in: Capsule())
                                        .foregroundStyle(item.measurability.badgeColor)

                                    Text(item.recommendation.rawValue)
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(item.recommendation.color.opacity(0.16), in: Capsule())
                                        .foregroundStyle(item.recommendation.color)
                                }

                                Text(item.locationPath)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }

                            Spacer()

                            Text(item.sizeBytes.map { ByteFormatting.string($0) } ?? "Restricted")
                                .font(.subheadline.monospacedDigit().weight(.bold))
                                .foregroundStyle(item.sizeBytes == nil ? .secondary : .primary)

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

                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                            GridRow {
                                Text("Explanation:")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(item.explanation)
                                    .font(.caption)
                            }
                            GridRow {
                                Text("Potential Risks:")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(item.potentialRisks)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.035))
                    )
                }
            }
        }
    }
}
