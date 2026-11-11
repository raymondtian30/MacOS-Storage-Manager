import SwiftUI
import Charts

public struct StorageHistoryView: View {
    @Bindable var appState: AppState
    @State private var selectedCategoryForChart: StorageCategory = .systemData

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    SectionHeaderBar(
                        title: "Storage History",
                        subtitle: "Persistent SQLite storage tracking across scans (\(appState.historySnapshots.count) recorded snapshots)",
                        icon: NavigationSection.history.icon
                    )

                    Button {
                        appState.startScan()
                    } label: {
                        Label("Record New Scan", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SpaceSenseTheme.accent)
                    .disabled(appState.isScanning)
                }

                usedStorageChartCard

                HStack(alignment: .top, spacing: 16) {
                    categoryTrendChartCard
                    growthDeltasCard
                }

                snapshotsTableCard
            }
            .padding(24)
        }
    }

    private var usedStorageChartCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Used vs. Available Disk Storage Over Time")
                            .font(.headline)
                        Text("Stored locally in SQLite (\(appState.historyStore.databasePath))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if appState.historySnapshots.isEmpty {
                    Text("Run your first storage scan to start recording historical disk utilization.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                } else {
                    Chart {
                        ForEach(appState.historySnapshots) { snap in
                            let usedGB = Double(snap.usedBytes) / 1_000_000_000.0
                            AreaMark(
                                x: .value("Scan Time", snap.timestamp),
                                y: .value("Used (GB)", usedGB)
                            )
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [SpaceSenseTheme.accent.opacity(0.45), SpaceSenseTheme.accent.opacity(0.05)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )

                            LineMark(
                                x: .value("Scan Time", snap.timestamp),
                                y: .value("Used (GB)", usedGB)
                            )
                            .foregroundStyle(SpaceSenseTheme.accent)
                            .lineStyle(StrokeStyle(lineWidth: 2.5))

                            PointMark(
                                x: .value("Scan Time", snap.timestamp),
                                y: .value("Used (GB)", usedGB)
                            )
                            .foregroundStyle(SpaceSenseTheme.accent)
                        }
                    }
                    .chartYAxisLabel("GB Used")
                    .frame(height: 210)
                }
            }
        }
    }

    private var categoryTrendChartCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Category Growth Trend")
                        .font(.headline)
                    Spacer()
                    Picker("Category", selection: $selectedCategoryForChart) {
                        ForEach(StorageCategory.allCases) { cat in
                            Text(cat.rawValue).tag(cat)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 150)
                }

                if appState.historySnapshots.isEmpty {
                    Text("No category history recorded yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                } else {
                    Chart {
                        ForEach(appState.historySnapshots) { snap in
                            let catBytes = snap.categoryBreakdown[selectedCategoryForChart.rawValue] ?? 0
                            let mbValue = Double(catBytes) / (1024.0 * 1024.0)
                            BarMark(
                                x: .value("Scan", snap.timestamp.formatted(date: .numeric, time: .shortened)),
                                y: .value("Size (MB)", mbValue)
                            )
                            .foregroundStyle(selectedCategoryForChart.color)
                        }
                    }
                    .chartYAxisLabel("MB")
                    .frame(height: 180)
                }
            }
        }
    }

    private var growthDeltasCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Growing Categories & Folders")
                    .font(.headline)
                Text("Changes between your two most recent scans")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.growthDeltas.isEmpty {
                    Text("Run at least two scans to compare folder and category growth.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 32)
                } else {
                    ForEach(appState.growthDeltas.prefix(8)) { delta in
                        HStack(spacing: 8) {
                            Image(systemName: delta.isFolder ? "folder.fill" : "tag.fill")
                                .foregroundStyle(delta.deltaBytes >= 0 ? SpaceSenseTheme.warning : SpaceSenseTheme.secondaryAccent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(delta.name)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("\(ByteFormatting.string(delta.previousBytes)) → \(ByteFormatting.string(delta.currentBytes))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            let sign = delta.deltaBytes >= 0 ? "+" : ""
                            Text("\(sign)\(ByteFormatting.string(delta.deltaBytes))")
                                .font(.caption.monospacedDigit().weight(.bold))
                                .foregroundStyle(delta.deltaBytes >= 0 ? SpaceSenseTheme.warning : SpaceSenseTheme.secondaryAccent)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var snapshotsTableCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Recorded Scan Snapshots")
                    .font(.headline)

                if appState.historySnapshots.isEmpty {
                    Text("No snapshots recorded yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.historySnapshots.reversed().prefix(15)) { snap in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snap.timestamp.formatted(date: .abbreviated, time: .standard))
                                    .font(.subheadline.weight(.medium))
                                Text("Scanned path: \(snap.scannedPath)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("Folder Size: \(ByteFormatting.string(snap.scannedRootBytes))")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                Text("Disk Used: \(ByteFormatting.string(snap.usedBytes)) • Free: \(ByteFormatting.string(snap.availableBytes))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }
        }
    }
}
