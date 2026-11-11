import SwiftUI
import AppKit

public struct SmartCleanupView: View {
    @Bindable var appState: AppState

    public enum HubMode: String, CaseIterable, Identifiable {
        case recommendations = "Safe & Unused Recommendations"
        case largeFiles = "All Large Files (250 MB – 1 GB+)"
        case duplicates = "Duplicate Groups (SHA-256)"

        public var id: String { rawValue }
    }

    @State private var hubMode: HubMode = .recommendations
    @State private var selectedKindFilter: CleanupKind?
    @State private var searchText: String = ""
    @State private var extensionFilter: String = ""
    @State private var onlyUnusedLargeFiles: Bool = false
    @State private var selectedLargeFileIDs: Set<String> = []
    @State private var previewingFile: LargeFileItem?
    @State private var showingReviewSheet: Bool = false

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerBar
            modeSelectorBar

            switch hubMode {
            case .recommendations:
                recommendationsContent
            case .largeFiles:
                largeFilesContent
            case .duplicates:
                duplicatesContent
            }
        }
        .padding(24)
        .sheet(item: $previewingFile) { item in
            DeleteHubPreviewModal(file: item, appState: appState)
        }
        .sheet(isPresented: $showingReviewSheet) {
            confirmationSheetContent
        }
    }

    private var headerBar: some View {
        let activeSelection = currentActionSummary()
        return HStack(spacing: 12) {
            SectionHeaderBar(
                title: "Delete Hub",
                subtitle: "Unified center for unused large files (> \(appState.unusedFileDaysThreshold)d), duplicates, caches, and safe cleanup",
                icon: NavigationSection.deleteHub.icon
            )

            Button {
                Task {
                    await appState.refreshCleanupRecommendationsAsync()
                }
            } label: {
                HStack(spacing: 6) {
                    if appState.isRefreshingCleanup {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(appState.isRefreshingCleanup ? "Analyzing…" : "Refresh Options")
                }
            }
            .buttonStyle(.bordered)
            .disabled(appState.isRefreshingCleanup)

            Button {
                showingReviewSheet = true
            } label: {
                Label(
                    "Review & Move \(activeSelection.count) to Trash (\(ByteFormatting.string(activeSelection.bytes)))",
                    systemImage: "trash.fill"
                )
                .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .tint(SpaceSenseTheme.secondaryAccent)
            .disabled(activeSelection.count == 0)
        }
    }

    private var modeSelectorBar: some View {
        SurfaceCard(padding: 12) {
            HStack(spacing: 14) {
                Picker("View", selection: $hubMode) {
                    ForEach(HubMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 620)

                Spacer()

                HStack(spacing: 6) {
                    Text("Unused Period:")
                        .font(.caption)
                        .foregroundStyle(SpaceSenseTheme.slate)
                    Picker("Unused Period", selection: $appState.unusedFileDaysThreshold) {
                        ForEach(AppState.unusedDaysOptions, id: \.days) { opt in
                            Text(opt.label).tag(opt.days)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 115)
                    InfoTooltipIcon("Files that have not been opened or modified in macOS for at least this many days are flagged as Unused Large Files.")
                }

                HStack(spacing: 6) {
                    Text("Large Size:")
                        .font(.caption)
                        .foregroundStyle(SpaceSenseTheme.slate)
                    Picker("Large File Size", selection: $appState.largeFileThresholdMB) {
                        ForEach(AppState.largeFileThresholdOptionsMB, id: \.value) { opt in
                            Text(opt.label).tag(opt.value)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 90)
                }
            }
        }
    }

    // MARK: - 1. Recommendations & Unused Large Files Mode

    private var recommendationsContent: some View {
        let filtered = filteredCandidates()
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        filterPill(title: "All (\(appState.cleanupCandidates.count))", isSelected: selectedKindFilter == nil) {
                            selectedKindFilter = nil
                        }
                        ForEach(CleanupKind.allCases) { kind in
                            let count = appState.cleanupCandidates.filter { $0.kind == kind }.count
                            filterPill(title: "\(kind.rawValue) (\(count))", icon: kind.icon, isSelected: selectedKindFilter == kind) {
                                selectedKindFilter = kind
                            }
                        }
                    }
                }

                Spacer()

                Button("Select All Safe") {
                    for idx in appState.cleanupCandidates.indices {
                        if let filter = selectedKindFilter, appState.cleanupCandidates[idx].kind != filter {
                            continue
                        }
                        if appState.cleanupCandidates[idx].risk == .low {
                            appState.cleanupCandidates[idx].isSelected = true
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Clear Selection") {
                    for idx in appState.cleanupCandidates.indices {
                        appState.cleanupCandidates[idx].isSelected = false
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            SurfaceCard(padding: 0) {
                if filtered.isEmpty {
                    emptyHubState(
                        title: "No Cleanup Candidates in This Category",
                        detail: "Run a storage scan or lower the unused time period above to find unused large files, caches, installers, and duplicate copies."
                    )
                } else {
                    List(filtered) { candidate in
                        candidateRow(candidate)
                    }
                    .listStyle(.inset)
                }
            }
        }
    }

    private func candidateRow(_ candidate: CleanupCandidate) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Toggle(
                "",
                isOn: Binding(
                    get: { candidate.isSelected },
                    set: { checked in
                        if let idx = appState.cleanupCandidates.firstIndex(where: { $0.id == candidate.id }) {
                            appState.cleanupCandidates[idx].isSelected = checked
                        }
                    }
                )
            )
            .toggleStyle(.checkbox)
            .labelsHidden()
            .padding(.top, 4)

            Image(systemName: candidate.kind.icon)
                .font(.title3)
                .foregroundStyle(SpaceSenseTheme.accent)
                .frame(width: 26)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(candidate.title)
                        .font(.subheadline.weight(.bold))

                    Text(candidate.kind.rawValue)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(SpaceSenseTheme.slate.opacity(0.15), in: Capsule())

                    Text(candidate.risk.rawValue)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(candidate.risk.color.opacity(0.18), in: Capsule())
                        .foregroundStyle(candidate.risk.color)

                    if let lastUsed = candidate.lastUsedDate {
                        Text("Last used \(lastUsed.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption2)
                            .foregroundStyle(SpaceSenseTheme.slate)
                    }
                }

                Text(candidate.locationURL.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(SpaceSenseTheme.slate)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("\(candidate.whyRecommended) • \(candidate.potentialConsequences)")
                    .font(.caption)
                    .foregroundStyle(SpaceSenseTheme.slate)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text(ByteFormatting.string(candidate.sizeBytes))
                    .font(.headline.monospacedDigit())

                Button {
                    appState.revealInFinder(candidate.locationURL)
                } label: {
                    Label("Reveal", systemImage: "folder")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - 2. Large Files Mode (250 MB – 1 GB+)

    private var largeFilesContent: some View {
        let files = filteredLargeFiles()
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TextField("Search filename or path…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)

                TextField("Ext (e.g. mov, dmg)", text: $extensionFilter)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 140)

                Toggle("Only unused >= \(appState.unusedFileDaysThreshold) days", isOn: $onlyUnusedLargeFiles)
                    .font(.caption)
                    .toggleStyle(.checkbox)

                Spacer()
            }

            SurfaceCard(padding: 0) {
                if files.isEmpty {
                    emptyHubState(
                        title: appState.latestScanResult == nil ? "Run a Storage Scan First" : "No Files >= \(Int(appState.largeFileThresholdMB)) MB Match Filters",
                        detail: "Change the Large Size threshold between 250 MB and 1 GB above or clear your search filter."
                    )
                } else {
                    List(files) { file in
                        largeFileRow(file)
                    }
                    .listStyle(.inset)
                }
            }
        }
    }

    private func largeFileRow(_ file: LargeFileItem) -> some View {
        let isSelected = selectedLargeFileIDs.contains(file.id)
        let daysUnused = file.daysSinceLastOpened()
        let isStale = daysUnused >= appState.unusedFileDaysThreshold

        return HStack(spacing: 12) {
            Toggle(
                "",
                isOn: Binding(
                    get: { isSelected },
                    set: { checked in
                        if checked {
                            selectedLargeFileIDs.insert(file.id)
                        } else {
                            selectedLargeFileIDs.remove(file.id)
                        }
                    }
                )
            )
            .toggleStyle(.checkbox)
            .labelsHidden()

            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                .resizable()
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if isStale {
                        Text("Unused \(daysUnused)d")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(SpaceSenseTheme.secondaryAccent.opacity(0.18), in: Capsule())
                            .foregroundStyle(SpaceSenseTheme.secondaryAccent)
                    } else {
                        Text("Opened \(daysUnused)d ago")
                            .font(.caption2)
                            .foregroundStyle(SpaceSenseTheme.slate)
                    }
                }
                Text(file.path)
                    .font(.caption2)
                    .foregroundStyle(SpaceSenseTheme.slate)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(ByteFormatting.string(file.size))
                .font(.subheadline.monospacedDigit().weight(.bold))
                .frame(width: 90, alignment: .trailing)

            HStack(spacing: 6) {
                Button {
                    previewingFile = file
                } label: {
                    Image(systemName: "eye")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Preview File")

                Button {
                    appState.revealInFinder(file.url)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reveal in Finder")

                Button {
                    appState.openFile(file.url)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open File")
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 3. Exact Duplicates Mode (SHA-256)

    private var duplicatesContent: some View {
        let groups = filteredDuplicateGroups()
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                TextField("Filter duplicate filenames or paths…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 260)

                HStack(spacing: 4) {
                    Text("SHA-256 Verified")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SpaceSenseTheme.secondaryAccent)
                    InfoTooltipIcon("SpaceSense verifies byte-for-byte identity using Apple CryptoKit SHA-256 digests and never matches files by filename alone. At least one copy per group is always preserved.")
                }

                Spacer()

                if appState.isFindingDuplicates {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Hashing (\(appState.duplicateProgress.processed)/\(appState.duplicateProgress.total))…")
                            .font(.caption)
                        Button("Stop") {
                            appState.cancelDuplicateScan()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                } else {
                    Button("Re-scan Duplicates") {
                        Task { await appState.runDuplicateScan() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(appState.latestScanResult == nil)
                }
            }

            SurfaceCard(padding: 0) {
                if groups.isEmpty {
                    emptyHubState(
                        title: "No Exact Duplicate Files Found",
                        detail: "Run a storage scan to detect byte-identical duplicate files across folders."
                    )
                } else {
                    List {
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.files) { file in
                                    HStack(spacing: 12) {
                                        Button {
                                            appState.toggleDuplicateSelection(groupID: group.id, fileID: file.id)
                                        } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: file.isMarkedForRemoval ? "trash.circle.fill" : "shield.lefthalf.filled")
                                                    .foregroundStyle(file.isMarkedForRemoval ? SpaceSenseTheme.accent : SpaceSenseTheme.secondaryAccent)
                                                Text(file.isMarkedForRemoval ? "Move to Trash" : "Keep Original")
                                                    .font(.caption.weight(.semibold))
                                            }
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(
                                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                    .fill((file.isMarkedForRemoval ? SpaceSenseTheme.accent : SpaceSenseTheme.secondaryAccent).opacity(0.15))
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .frame(width: 130, alignment: .leading)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(file.name).font(.subheadline.weight(.medium))
                                            Text(file.path)
                                                .font(.caption2)
                                                .foregroundStyle(SpaceSenseTheme.slate)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        Spacer()
                                        Text(ByteFormatting.string(file.size))
                                            .font(.caption.monospacedDigit().weight(.semibold))
                                        Button {
                                            appState.revealInFinder(file.url)
                                        } label: {
                                            Image(systemName: "folder")
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                    .padding(.vertical, 2)
                                }
                            } header: {
                                HStack {
                                    Text("\(group.files.count) identical copies • \(ByteFormatting.string(group.fileSize)) each")
                                        .font(.caption.weight(.bold))
                                    Text("SHA-256: \(String(group.sha256Hash.prefix(14)))…")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(SpaceSenseTheme.slate)
                                    Spacer()
                                    Text("Reclaimable: \(ByteFormatting.string(group.reclaimableBytes))")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(SpaceSenseTheme.secondaryAccent)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
        }
    }

    // MARK: - Helpers & Review Sheet

    private func filterPill(title: String, icon: String? = nil, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                }
                Text(title)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(isSelected ? SpaceSenseTheme.accent : SpaceSenseTheme.slate.opacity(0.12))
            )
            .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func emptyHubState(title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 38))
                .foregroundStyle(SpaceSenseTheme.secondaryAccent)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(SpaceSenseTheme.slate)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func filteredCandidates() -> [CleanupCandidate] {
        guard let kind = selectedKindFilter else {
            return appState.cleanupCandidates
        }
        return appState.cleanupCandidates.filter { $0.kind == kind }
    }

    private func filteredLargeFiles() -> [LargeFileItem] {
        guard let scan = appState.latestScanResult else { return [] }
        let minBytes = Int64(appState.largeFileThresholdMB * 1024 * 1024)
        let source = scan.allFiles.isEmpty ? scan.largeFiles : scan.allFiles
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ext = extensionFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: ".", with: "")

        return source
            .filter { item in
                guard item.size >= minBytes else { return false }
                if onlyUnusedLargeFiles && item.daysSinceLastOpened() < appState.unusedFileDaysThreshold {
                    return false
                }
                if !q.isEmpty && !item.name.lowercased().contains(q) && !item.path.lowercased().contains(q) {
                    return false
                }
                if !ext.isEmpty && item.fileExtension != ext {
                    return false
                }
                return true
            }
            .sorted { $0.size > $1.size }
    }

    private func filteredDuplicateGroups() -> [DuplicateGroup] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return appState.duplicateGroups }
        return appState.duplicateGroups.filter { group in
            group.files.contains { $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q) }
        }
    }

    private func currentActionSummary() -> (urls: [URL], sizes: [URL: Int64], descriptions: [(name: String, path: String, size: Int64)], count: Int, bytes: Int64) {
        switch hubMode {
        case .recommendations:
            let selected = filteredCandidates().filter(\.isSelected)
            let urls = selected.map(\.locationURL)
            let sizes = Dictionary(uniqueKeysWithValues: selected.map { ($0.locationURL, $0.sizeBytes) })
            let descs = selected.map { ($0.title, $0.locationURL.path, $0.sizeBytes) }
            let total = selected.reduce(Int64(0)) { $0 + $1.sizeBytes }
            return (urls, sizes, descs, selected.count, total)
        case .largeFiles:
            let selected = filteredLargeFiles().filter { selectedLargeFileIDs.contains($0.id) }
            let urls = selected.map(\.url)
            let sizes = Dictionary(uniqueKeysWithValues: selected.map { ($0.url, $0.size) })
            let descs = selected.map { ($0.name, $0.path, $0.size) }
            let total = selected.reduce(Int64(0)) { $0 + $1.size }
            return (urls, sizes, descs, selected.count, total)
        case .duplicates:
            let selected = filteredDuplicateGroups().flatMap { $0.files.filter(\.isMarkedForRemoval) }
            let urls = selected.map(\.url)
            let sizes = Dictionary(uniqueKeysWithValues: selected.map { ($0.url, $0.size) })
            let descs = selected.map { ($0.name, $0.path, $0.size) }
            let total = selected.reduce(Int64(0)) { $0 + $1.size }
            return (urls, sizes, descs, selected.count, total)
        }
    }

    private var confirmationSheetContent: some View {
        let summary = currentActionSummary()
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "trash.slash.fill")
                    .font(.title)
                    .foregroundStyle(SpaceSenseTheme.secondaryAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Confirm Move to Trash — \(summary.count) Item(s)")
                        .font(.headline)
                    Text("Reclaims \(ByteFormatting.string(summary.bytes)). Selected items will be moved safely to your macOS Trash and are never permanently deleted.")
                        .font(.caption)
                        .foregroundStyle(SpaceSenseTheme.slate)
                }
            }

            List(Array(summary.descriptions.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(entry.name).font(.caption.weight(.bold))
                        Spacer()
                        Text(ByteFormatting.string(entry.size)).font(.caption.monospacedDigit().weight(.semibold))
                    }
                    Text(entry.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(SpaceSenseTheme.slate)
                }
                .padding(.vertical, 2)
            }
            .frame(height: 230)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    showingReviewSheet = false
                }
                Button("Move \(summary.count) Item(s) to Trash") {
                    Task {
                        _ = await appState.moveURLsToTrash(summary.urls, sizes: summary.sizes)
                        selectedLargeFileIDs.removeAll()
                        showingReviewSheet = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(SpaceSenseTheme.secondaryAccent)
            }
        }
        .padding(20)
        .frame(width: 540)
    }
}

private struct DeleteHubPreviewModal: View {
    let file: LargeFileItem
    let appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                    .resizable()
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).font(.headline)
                    Text(file.path)
                        .font(.caption)
                        .foregroundStyle(SpaceSenseTheme.slate)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Close") { dismiss() }
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Size:").foregroundStyle(SpaceSenseTheme.slate)
                    Text(ByteFormatting.string(file.size)).fontWeight(.semibold)
                }
                GridRow {
                    Text("Last Opened / Used:").foregroundStyle(SpaceSenseTheme.slate)
                    Text("\(file.daysSinceLastOpened()) days ago (\(file.lastUsedDate?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown"))")
                }
            }
            .font(.subheadline)

            if ["jpg", "jpeg", "png", "heic", "gif", "webp", "tiff", "bmp"].contains(file.fileExtension),
               let image = NSImage(contentsOf: file.url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 260)
                    .frame(maxWidth: .infinity)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            } else if ["txt", "md", "json", "log", "swift", "py", "csv", "xml", "yaml", "yml"].contains(file.fileExtension),
                      let snippet = Self.readSnippet(url: file.url) {
                ScrollView {
                    Text(snippet)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 200)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text("Inline preview is supported for image and text files. Use 'Open in Default App' or 'Reveal in Finder' below.")
                    .font(.caption)
                    .foregroundStyle(SpaceSenseTheme.slate)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Button("Reveal in Finder") { appState.revealInFinder(file.url) }
                Button("Open in Default App") { appState.openFile(file.url) }
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private static func readSnippet(url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
