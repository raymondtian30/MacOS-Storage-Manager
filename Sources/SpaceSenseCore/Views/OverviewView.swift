import SwiftUI

public struct OverviewView: View {
    @Bindable var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerRow

                if appState.isScanning {
                    ScanProgressBanner(progress: appState.scanProgress) {
                        appState.cancelScan()
                    }
                }

                topMetricsGrid
                storageBarSection

                HStack(alignment: .top, spacing: 16) {
                    recentLargeFilesCard
                    rightColumnCards
                }
            }
            .padding(24)
        }
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 16) {
            SectionHeaderBar(
                title: "Storage Overview",
                subtitle: "Real-time disk telemetry for \(appState.volumeStats.volumeName)",
                icon: NavigationSection.overview.icon
            )

            HStack(spacing: 10) {
                Button {
                    appState.chooseDirectoryAndScan()
                } label: {
                    Label("Choose Folder…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
                .disabled(appState.isScanning)

                Button {
                    appState.startScan()
                } label: {
                    Label(
                        appState.isScanning ? "Scanning…" : "Start Storage Scan",
                        systemImage: "play.fill"
                    )
                    .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(SpaceSenseTheme.accent)
                .disabled(appState.isScanning)
            }
        }
    }

    private var topMetricsGrid: some View {
        let stats = appState.volumeStats
        let utilizationText = String(format: "%.1f%%", stats.utilizationPercentage)
        let lastScanText: String = {
            if let last = appState.latestScanResult?.timestamp ?? appState.historySnapshots.last?.timestamp {
                return last.formatted(date: .abbreviated, time: .shortened)
            }
            return "Not scanned yet"
        }()

        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4),
            spacing: 14
        ) {
            MetricCardView(
                title: "Total Disk Capacity",
                value: ByteFormatting.string(stats.totalBytes),
                subtitle: "Volume: \(stats.volumeName)",
                icon: "internaldrive.fill",
                tint: SpaceSenseTheme.accent
            )
            MetricCardView(
                title: "Used Storage (\(utilizationText))",
                value: ByteFormatting.string(stats.usedBytes),
                subtitle: "Last scan: \(lastScanText)",
                icon: "chart.pie.fill",
                tint: stats.utilizationPercentage > 85 ? SpaceSenseTheme.danger : SpaceSenseTheme.warning
            )
            MetricCardView(
                title: "Available Storage",
                value: ByteFormatting.string(stats.availableBytes),
                subtitle: "Free purgable-aware capacity",
                icon: "checkmark.shield.fill",
                tint: SpaceSenseTheme.secondaryAccent
            )
            MetricCardView(
                title: "Potentially Reclaimable",
                value: ByteFormatting.string(appState.totalReclaimableBytes),
                subtitle: "\(appState.cleanupCandidates.count) safe cleanup items",
                icon: "sparkles",
                tint: .purple
            )
        }
    }

    private var storageBarSection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Storage Breakdown by Category")
                            .font(.headline)
                        if let result = appState.latestScanResult {
                            Text("Measured in \(result.rootURL.path) (\(ByteFormatting.string(result.rootNode.size)) across \(result.totalFilesScanned.formatted()) files)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Run a scan on your Home folder or another directory to break down file categories. System Data probes are shown below.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text("\(String(format: "%.1f%%", appState.volumeStats.utilizationPercentage)) Used")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                GeometryReader { geo in
                    let totalWidth = max(geo.size.width - 16, 1)
                    let segments = categorySegments()
                    HStack(spacing: 2) {
                        ForEach(segments, id: \.category) { segment in
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(segment.category.color)
                                .frame(width: max(4, totalWidth * segment.fraction))
                                .help("\(segment.category.rawValue): \(ByteFormatting.string(segment.bytes))")
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .frame(height: 18)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                    spacing: 10
                ) {
                    ForEach(StorageCategory.allCases) { category in
                        let bytes = categoryByteValue(for: category)
                        Button {
                            appState.analyzerCategoryFilter = category
                            appState.selectedSection = .analyzer
                        } label: {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(category.color)
                                    .frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(category.rawValue)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(ByteFormatting.string(bytes))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.04))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var recentLargeFilesCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Recently Detected Large Files")
                        .font(.headline)
                    Spacer()
                    Button("View All") {
                        appState.selectedSection = .largeFiles
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }

                if let files = appState.latestScanResult?.largeFiles, !files.isEmpty {
                    ForEach(files.prefix(7)) { file in
                        HStack(spacing: 10) {
                            Image(systemName: file.category.icon)
                                .foregroundStyle(file.category.color)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text(file.path)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Text(ByteFormatting.string(file.size))
                                .font(.caption.monospacedDigit().weight(.semibold))
                            Button {
                                appState.revealInFinder(file.url)
                            } label: {
                                Image(systemName: "magnifyingglass.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Reveal in Finder")
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.badge.gearshape")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("Start a storage scan to list the largest files in your selected directory.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                }
            }
        }
    }

    private var rightColumnCards: some View {
        VStack(spacing: 16) {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Smart Cleanup Summary")
                            .font(.headline)
                        Spacer()
                        Button("Review Cleanup") {
                            appState.selectedSection = .smartCleanup
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }

                    Text(ByteFormatting.string(appState.totalReclaimableBytes))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(SpaceSenseTheme.secondaryAccent)

                    Text("Identified across \(appState.cleanupCandidates.count) safe candidates (caches, logs, Xcode DerivedData, installers, and duplicate copies).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            SurfaceCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Recent Storage Changes")
                            .font(.headline)
                        Spacer()
                        Button("History") {
                            appState.selectedSection = .history
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }

                    if appState.growthDeltas.isEmpty {
                        Text("Run two or more scans to see which categories and folders have grown or shrunk.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(appState.growthDeltas.prefix(5)) { delta in
                            HStack {
                                Image(systemName: delta.deltaBytes >= 0 ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill")
                                    .foregroundStyle(delta.deltaBytes >= 0 ? SpaceSenseTheme.warning : SpaceSenseTheme.secondaryAccent)
                                Text(delta.name)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                let sign = delta.deltaBytes >= 0 ? "+" : ""
                                Text("\(sign)\(ByteFormatting.string(delta.deltaBytes))")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(delta.deltaBytes >= 0 ? SpaceSenseTheme.warning : SpaceSenseTheme.secondaryAccent)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 340)
    }

    private func categoryByteValue(for category: StorageCategory) -> Int64 {
        if let scan = appState.latestScanResult {
            if category == .systemData {
                let scannedSys = scan.categoryBytes[.systemData] ?? 0
                let measuredSys = appState.systemDataReport?.totalMeasuredBytes ?? 0
                return max(scannedSys, measuredSys)
            }
            return scan.categoryBytes[category] ?? 0
        }
        if category == .systemData {
            return appState.systemDataReport?.totalMeasuredBytes ?? 0
        }
        return 0
    }

    private func categorySegments() -> [(category: StorageCategory, bytes: Int64, fraction: CGFloat)] {
        let nonZero = StorageCategory.allCases.compactMap { cat -> (StorageCategory, Int64)? in
            let bytes = categoryByteValue(for: cat)
            return bytes > 0 ? (cat, bytes) : nil
        }
        let sumBytes = nonZero.reduce(Int64(0)) { $0 + $1.1 }
        let denominator = max(Double(sumBytes), 1)
        let utilRatio = min(0.96, max(0.15, appState.volumeStats.utilizationPercentage / 100.0))
        return nonZero.map { (cat, bytes) in
            let fraction = (Double(bytes) / denominator) * utilRatio
            return (cat, bytes, CGFloat(max(0.01, fraction)))
        }
    }
}
