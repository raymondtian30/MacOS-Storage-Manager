import SwiftUI

public struct OverviewView: View {
    @Bindable var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        GeometryReader { geo in
            let isCompact = geo.size.width < 720
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerRow
                    topMetricsGrid
                    storageBarSection

                    if isCompact {
                        VStack(alignment: .leading, spacing: 16) {
                            recentLargeFilesCard
                            rightColumnCards
                        }
                    } else {
                        HStack(alignment: .top, spacing: 16) {
                            recentLargeFilesCard
                                .frame(maxWidth: .infinity)
                            rightColumnCards
                                .frame(minWidth: 230, idealWidth: 290, maxWidth: 340)
                        }
                    }
                }
                .padding(isCompact ? 14 : 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var headerRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                SectionHeaderBar(
                    title: "Storage Overview",
                    subtitle: "Disk telemetry for \(appState.volumeStats.volumeName)",
                    icon: NavigationSection.overview.icon
                )
                scanActionButtons
            }
            VStack(alignment: .leading, spacing: 10) {
                SectionHeaderBar(
                    title: "Storage Overview",
                    subtitle: "Disk telemetry for \(appState.volumeStats.volumeName)",
                    icon: NavigationSection.overview.icon
                )
                scanActionButtons
            }
        }
    }

    private var scanActionButtons: some View {
        HStack(spacing: 8) {
            Button {
                appState.chooseDirectoryAndScan()
            } label: {
                Label("Choose Folder…", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.bordered)

            Button {
                appState.requestStartScan(at: FileManager.default.homeDirectoryForCurrentUser)
            } label: {
                Label("Scan Home Directory", systemImage: "play.fill")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .tint(SpaceSenseTheme.accent)
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
            columns: [GridItem(.adaptive(minimum: 155, maximum: 320), spacing: 12)],
            spacing: 12
        ) {
            MetricCardView(
                title: "Total Capacity",
                value: ByteFormatting.string(stats.totalBytes),
                subtitle: "Volume: \(stats.volumeName)",
                icon: "internaldrive.fill",
                tint: SpaceSenseTheme.slate
            )
            MetricCardView(
                title: "Used (\(utilizationText))",
                value: ByteFormatting.string(stats.usedBytes),
                subtitle: "Last scan: \(lastScanText)",
                icon: "chart.pie.fill",
                tint: SpaceSenseTheme.accent
            )
            MetricCardView(
                title: "Available Space",
                value: ByteFormatting.string(stats.availableBytes),
                subtitle: "Purgeable-aware capacity",
                icon: "checkmark.shield.fill",
                tint: SpaceSenseTheme.secondaryAccent,
                tooltip: "Includes APFS purgeable space that macOS automatically frees when applications request disk storage."
            )
            Button {
                appState.selectedSection = .deleteHub
            } label: {
                MetricCardView(
                    title: "Delete Hub Reclaimable",
                    value: ByteFormatting.string(appState.totalReclaimableBytes),
                    subtitle: "\(appState.cleanupCandidates.count) reviewable items",
                    icon: "trash.slash.fill",
                    tint: SpaceSenseTheme.secondaryAccent
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var storageBarSection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Storage Breakdown by Category")
                            .font(.headline)
                        if let result = appState.latestScanResult {
                            Text("Measured in \(result.rootURL.path) (\(ByteFormatting.string(result.rootNode.size)) across \(result.totalFilesScanned.formatted()) files)")
                                .font(.caption)
                                .foregroundStyle(SpaceSenseTheme.slate)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        } else {
                            Text("Click 'Scan Home Directory' to measure category sizes across your files.")
                                .font(.caption)
                                .foregroundStyle(SpaceSenseTheme.slate)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                    }
                    Spacer(minLength: 8)
                    Text("\(String(format: "%.1f%%", appState.volumeStats.utilizationPercentage)) Used")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(SpaceSenseTheme.slate)
                }

                GeometryReader { geo in
                    let segments = categorySegments()
                    let spacingTotal = CGFloat(max(0, segments.count - 1)) * 2.0
                    let availableWidth = max(1, geo.size.width - spacingTotal)
                    HStack(spacing: 2) {
                        ForEach(segments, id: \.category) { segment in
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(segment.category.color)
                                .frame(width: max(3, availableWidth * segment.fraction))
                                .help("\(segment.category.rawValue): \(ByteFormatting.string(segment.bytes))")
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(SpaceSenseTheme.slate.opacity(0.15))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .frame(height: 16)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 140, maximum: 260), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(StorageCategory.allCases) { category in
                        let bytes = categoryByteValue(for: category)
                        Button {
                            appState.analyzerCategoryFilter = category
                            appState.selectedSection = .analyzer
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(category.color)
                                    .frame(width: 9, height: 9)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(category.rawValue)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                    Text(ByteFormatting.string(bytes))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(SpaceSenseTheme.slate)
                                }
                                Spacer(minLength: 2)
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(SpaceSenseTheme.slate.opacity(0.08))
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
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Largest Detected Files")
                        .font(.headline)
                    Spacer()
                    Button("Open Delete Hub") {
                        appState.selectedSection = .deleteHub
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }

                if let files = appState.latestScanResult?.largeFiles, !files.isEmpty {
                    let topFiles = Array(files.prefix(7))
                    ForEach(Array(topFiles.enumerated()), id: \.element.id) { idx, file in
                        HStack(spacing: 8) {
                            Image(systemName: file.category.icon)
                                .foregroundStyle(SpaceSenseTheme.accent)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                Text("Last opened \(file.daysSinceLastOpened())d ago • \(file.path)")
                                    .font(.caption2)
                                    .foregroundStyle(SpaceSenseTheme.slate)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(file.path)
                            }
                            Spacer(minLength: 4)
                            Text(ByteFormatting.string(file.size))
                                .font(.caption.monospacedDigit().weight(.semibold))
                            Button {
                                appState.revealInFinder(file.url)
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.borderless)
                            .help("Reveal in Finder")
                        }
                        .padding(.vertical, 3)
                        .contextMenu {
                            Button("Reveal in Finder") { appState.revealInFinder(file.url) }
                            Button("Open File") { appState.openFile(file.url) }
                            Button("Copy Path") { appState.copyPathToClipboard(file.path) }
                        }

                        if idx < topFiles.count - 1 {
                            Divider()
                        }
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.up.doc")
                            .font(.title2)
                            .foregroundStyle(SpaceSenseTheme.slate)
                        Text("Run a scan to list files >= \(Int(appState.largeFileThresholdMB)) MB.")
                            .font(.caption)
                            .foregroundStyle(SpaceSenseTheme.slate)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            }
        }
    }

    private var rightColumnCards: some View {
        VStack(spacing: 14) {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Delete Hub")
                            .font(.headline)
                        Spacer()
                        Button("Review Items") {
                            appState.selectedSection = .deleteHub
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }

                    Text(ByteFormatting.string(appState.totalReclaimableBytes))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(SpaceSenseTheme.secondaryAccent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Text("Across \(appState.cleanupCandidates.count) unused large files (> \(appState.unusedFileDaysThreshold)d), exact duplicates, caches, and installers.")
                        .font(.caption)
                        .foregroundStyle(SpaceSenseTheme.slate)
                }
            }

            SurfaceCard {
                VStack(alignment: .leading, spacing: 8) {
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
                        Text("Run two or more scans to see which categories and folders are growing.")
                            .font(.caption)
                            .foregroundStyle(SpaceSenseTheme.slate)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(appState.growthDeltas.prefix(5)) { delta in
                            HStack {
                                Image(systemName: delta.deltaBytes >= 0 ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill")
                                    .foregroundStyle(delta.deltaBytes >= 0 ? SpaceSenseTheme.accent : SpaceSenseTheme.secondaryAccent)
                                Text(delta.name)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(delta.name)
                                Spacer(minLength: 4)
                                let sign = delta.deltaBytes >= 0 ? "+" : ""
                                Text("\(sign)\(ByteFormatting.string(delta.deltaBytes))")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(delta.deltaBytes >= 0 ? SpaceSenseTheme.accent : SpaceSenseTheme.secondaryAccent)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
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
        let utilRatio = min(0.96, max(0.04, appState.volumeStats.utilizationPercentage / 100.0))
        return nonZero.map { (cat, bytes) in
            let fraction = (Double(bytes) / denominator) * utilRatio
            return (cat, bytes, CGFloat(max(0.008, fraction)))
        }
    }
}
