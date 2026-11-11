import SwiftUI
import AppKit

public struct SmartCleanupView: View {
    @Bindable var appState: AppState

    public enum HubMode: String, CaseIterable, Identifiable {
        case recommendations = "Recommendations"
        case largeFiles = "Large Files"
        case duplicates = "Duplicates (SHA-256)"

        public var id: String { rawValue }
    }

    public enum LargeFileSortOrder: String, CaseIterable, Identifiable {
        case sizeDesc = "Largest First"
        case unusedDesc = "Most Unused First"
        case nameAsc = "Name (A–Z)"

        public var id: String { rawValue }
    }

    @State private var hubMode: HubMode = .recommendations
    @State private var selectedKindFilter: CleanupKind?
    @State private var searchText: String = ""
    @State private var extensionFilter: String = ""
    @State private var onlyUnusedLargeFiles: Bool = false
    @State private var largeFileSortOrder: LargeFileSortOrder = .sizeDesc
    @State private var selectedLargeFileIDs: Set<String> = []
    @State private var previewingFile: LargeFileItem?
    @State private var showingReviewSheet: Bool = false

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        GeometryReader { geo in
            let isCompact = geo.size.width < 720
            VStack(alignment: .leading, spacing: 12) {
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
            .padding(isCompact ? 14 : 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .sheet(item: $previewingFile) { item in
            DeleteHubPreviewModal(file: item, appState: appState)
        }
        .sheet(isPresented: $showingReviewSheet) {
            confirmationSheetContent
        }
    }

    private var headerBar: some View {
        let activeSelection = currentActionSummary()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                SectionHeaderBar(
                    title: "Delete Hub",
                    subtitle: "Unused large files (> \(appState.unusedFileDaysThreshold)d), duplicates, caches, and safe cleanup",
                    icon: NavigationSection.deleteHub.icon
                )
                headerActionButtons(activeSelection: activeSelection)
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionHeaderBar(
                    title: "Delete Hub",
                    subtitle: "Unused large files (> \(appState.unusedFileDaysThreshold)d), duplicates, caches, and safe cleanup",
                    icon: NavigationSection.deleteHub.icon
                )
                headerActionButtons(activeSelection: activeSelection)
            }
        }
    }

    private func headerActionButtons(activeSelection: (urls: [URL], sizes: [URL: Int64], descriptions: [(name: String, path: String, size: Int64)], count: Int, bytes: Int64)) -> some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    await appState.refreshCleanupRecommendationsAsync()
                }
            } label: {
                HStack(spacing: 5) {
                    if appState.isRefreshingCleanup {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(appState.isRefreshingCleanup ? "Analyzing…" : "Refresh Options")
                        .lineLimit(1)
                }
            }
            .buttonStyle(.bordered)
            .disabled(appState.isRefreshingCleanup)

            Button {
                showingReviewSheet = true
            } label: {
                Label(
                    "Move \(activeSelection.count) to Trash (\(ByteFormatting.string(activeSelection.bytes)))",
                    systemImage: "trash.fill"
                )
                .fontWeight(.semibold)
                .lineLimit(1)
            }
            .buttonStyle(.borderedProminent)
            .tint(SpaceSenseTheme.accent)
            .disabled(activeSelection.count == 0)
        }
    }

    private var modeSelectorBar: some View {
        SurfaceCard(padding: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    modePicker
                    Spacer(minLength: 8)
                    thresholdPickers
                }
                VStack(alignment: .leading, spacing: 8) {
                    modePicker
                    thresholdPickers
                }
            }
        }
    }

    private var modePicker: some View {
        Picker("View", selection: $hubMode) {
            ForEach(HubMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(minWidth: 240, maxWidth: 420)
    }

    private var thresholdPickers: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                Text("Unused:")
                    .font(.caption)
                    .foregroundStyle(SpaceSenseTheme.slate)
                    .lineLimit(1)
                Picker("Unused Period", selection: $appState.unusedFileDaysThreshold) {
                    ForEach(AppState.unusedDaysOptions, id: \.days) { opt in
                        Text(opt.label).tag(opt.days)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(minWidth: 95, maxWidth: 125)
                InfoTooltipIcon("Files that have not been opened or modified in macOS for at least this many days are flagged as Unused Large Files.")
            }

            HStack(spacing: 5) {
                Text("Min Size:")
                    .font(.caption)
                    .foregroundStyle(SpaceSenseTheme.slate)
                    .lineLimit(1)
                Picker("Large File Size", selection: $appState.largeFileThresholdMB) {
                    ForEach(AppState.largeFileThresholdOptionsMB, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(minWidth: 80, maxWidth: 95)
            }
        }
    }

    // MARK: - 1. Recommendations & Unused Large Files Mode

    private var recommendationsContent: some View {
        let filtered = filteredCandidates()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
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

                Spacer(minLength: 4)

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

                Button("Clear") {
                    for idx in appState.cleanupCandidates.indices {
                        if let filter = selectedKindFilter, appState.cleanupCandidates[idx].kind != filter {
                            continue
                        }
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
        HStack(alignment: .top, spacing: 10) {
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
                .font(.body)
                .foregroundStyle(SpaceSenseTheme.accent)
                .frame(width: 22)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(candidate.title)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(candidate.kind.rawValue)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(SpaceSenseTheme.slate.opacity(0.15), in: Capsule())
                        .lineLimit(1)

                    Text(candidate.risk.rawValue)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(candidate.risk.color.opacity(0.18), in: Capsule())
                        .foregroundStyle(candidate.risk.color)
                        .lineLimit(1)
                }

                Text(candidate.locationURL.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(SpaceSenseTheme.slate)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(candidate.locationURL.path)

                Text("\(candidate.whyRecommended) • \(candidate.potentialConsequences)")
                    .font(.caption)
                    .foregroundStyle(SpaceSenseTheme.slate)
                    .lineLimit(2)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 5) {
                Text(ByteFormatting.string(candidate.sizeBytes))
                    .font(.subheadline.monospacedDigit().weight(.bold))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if candidate.kind != .applicationCaches && candidate.kind != .developerArtifacts {
                        Button {
                            previewingFile = LargeFileItem(
                                url: candidate.locationURL,
                                size: candidate.sizeBytes,
                                modificationDate: candidate.lastUsedDate,
                                lastAccessDate: candidate.lastUsedDate
                            )
                        } label: {
                            Image(systemName: "eye")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Preview File")
                    }

                    Button {
                        appState.revealInFinder(candidate.locationURL)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Reveal in Finder")
                }
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            if let idx = appState.cleanupCandidates.firstIndex(where: { $0.id == candidate.id }) {
                appState.cleanupCandidates[idx].isSelected.toggle()
            }
        }
        .contextMenu {
            Button("Reveal in Finder") { appState.revealInFinder(candidate.locationURL) }
            Button("Open") { appState.openFile(candidate.locationURL) }
            Button("Copy Path") { appState.copyPathToClipboard(candidate.locationURL.path) }
        }
    }

    // MARK: - 2. Large Files Mode (250 MB – 1 GB+)

    private var largeFilesContent: some View {
        let files = filteredLargeFiles()
        return VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    TextField("Search filename or path…", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(minWidth: 110)

                    TextField("Ext", text: $extensionFilter)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 75)

                    Toggle("Unused >= \(appState.unusedFileDaysThreshold)d", isOn: $onlyUnusedLargeFiles)
                        .font(.caption)
                        .toggleStyle(.checkbox)

                    Picker("Sort", selection: $largeFileSortOrder) {
                        ForEach(LargeFileSortOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 135)

                    Spacer(minLength: 4)

                    largeFileSelectionButtons(files: files)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("Search filename or path…", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                        TextField("Ext", text: $extensionFilter)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .frame(width: 75)
                    }
                    HStack(spacing: 8) {
                        Toggle("Unused >= \(appState.unusedFileDaysThreshold)d", isOn: $onlyUnusedLargeFiles)
                            .font(.caption)
                            .toggleStyle(.checkbox)
                        Picker("Sort", selection: $largeFileSortOrder) {
                            ForEach(LargeFileSortOrder.allCases) { order in
                                Text(order.rawValue).tag(order)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 135)
                        Spacer()
                        largeFileSelectionButtons(files: files)
                    }
                }
            }

            SurfaceCard(padding: 0) {
                if files.isEmpty {
                    emptyHubState(
                        title: appState.latestScanResult == nil ? "Run a Storage Scan First" : "No Files >= \(Int(appState.largeFileThresholdMB)) MB Match Filters",
                        detail: "Change the Min Size threshold between 250 MB and 1 GB above or clear your search filter."
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

    private func largeFileSelectionButtons(files: [LargeFileItem]) -> some View {
        HStack(spacing: 6) {
            Button("Select All") {
                for f in files {
                    selectedLargeFileIDs.insert(f.id)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Clear") {
                for f in files {
                    selectedLargeFileIDs.remove(f.id)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func largeFileRow(_ file: LargeFileItem) -> some View {
        let isSelected = selectedLargeFileIDs.contains(file.id)
        let daysUnused = file.daysSinceLastOpened()
        let isStale = daysUnused >= appState.unusedFileDaysThreshold

        return HStack(spacing: 10) {
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
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if isStale {
                        Text("Unused \(daysUnused)d")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(SpaceSenseTheme.secondaryAccent.opacity(0.18), in: Capsule())
                            .foregroundStyle(SpaceSenseTheme.secondaryAccent)
                            .lineLimit(1)
                    } else {
                        Text("Opened \(daysUnused)d ago")
                            .font(.caption2)
                            .foregroundStyle(SpaceSenseTheme.slate)
                            .lineLimit(1)
                    }
                }
                Text(file.path)
                    .font(.caption2)
                    .foregroundStyle(SpaceSenseTheme.slate)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.path)
            }

            Spacer(minLength: 4)

            Text(ByteFormatting.string(file.size))
                .font(.subheadline.monospacedDigit().weight(.bold))
                .lineLimit(1)

            HStack(spacing: 4) {
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
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected {
                selectedLargeFileIDs.remove(file.id)
            } else {
                selectedLargeFileIDs.insert(file.id)
            }
        }
        .contextMenu {
            Button("Preview File") { previewingFile = file }
            Button("Reveal in Finder") { appState.revealInFinder(file.url) }
            Button("Open File") { appState.openFile(file.url) }
            Button("Copy Path") { appState.copyPathToClipboard(file.path) }
        }
    }

    // MARK: - 3. Exact Duplicates Mode (SHA-256)

    private var duplicatesContent: some View {
        let groups = filteredDuplicateGroups()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Filter duplicate filenames or paths…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(minWidth: 130, maxWidth: 250)

                HStack(spacing: 4) {
                    Text("SHA-256 Verified")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SpaceSenseTheme.secondaryAccent)
                        .lineLimit(1)
                    InfoTooltipIcon("SpaceSense verifies byte-for-byte identity using Apple CryptoKit SHA-256 digests and never matches files by filename alone. At least one copy per group is always preserved.")
                }

                Spacer(minLength: 4)

                if appState.isFindingDuplicates {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Hashing (\(appState.duplicateProgress.processed)/\(appState.duplicateProgress.total))…")
                            .font(.caption)
                            .lineLimit(1)
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
                                    HStack(spacing: 10) {
                                        Button {
                                            appState.toggleDuplicateSelection(groupID: group.id, fileID: file.id)
                                        } label: {
                                            HStack(spacing: 5) {
                                                Image(systemName: file.isMarkedForRemoval ? "trash.circle.fill" : "shield.lefthalf.filled")
                                                    .foregroundStyle(file.isMarkedForRemoval ? SpaceSenseTheme.accent : SpaceSenseTheme.secondaryAccent)
                                                Text(file.isMarkedForRemoval ? "Trash Copy" : "Keep Original")
                                                    .font(.caption.weight(.semibold))
                                                    .lineLimit(1)
                                            }
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(
                                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                    .fill((file.isMarkedForRemoval ? SpaceSenseTheme.accent : SpaceSenseTheme.secondaryAccent).opacity(0.15))
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .frame(width: 118, alignment: .leading)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(file.name)
                                                .font(.subheadline.weight(.medium))
                                                .lineLimit(1)
                                            Text(file.path)
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
                                            previewingFile = LargeFileItem(
                                                url: file.url,
                                                size: file.size,
                                                modificationDate: file.modificationDate
                                            )
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
                                    }
                                    .padding(.vertical, 2)
                                    .contextMenu {
                                        Button("Reveal in Finder") { appState.revealInFinder(file.url) }
                                        Button("Open File") { appState.openFile(file.url) }
                                        Button("Copy Path") { appState.copyPathToClipboard(file.path) }
                                    }
                                }
                            } header: {
                                HStack {
                                    Text("\(group.files.count) identical copies • \(ByteFormatting.string(group.fileSize)) each")
                                        .font(.caption.weight(.bold))
                                        .lineLimit(1)
                                    Text("SHA-256: \(String(group.sha256Hash.prefix(12)))…")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(SpaceSenseTheme.slate)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text("Reclaimable: \(ByteFormatting.string(group.reclaimableBytes))")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(SpaceSenseTheme.secondaryAccent)
                                        .lineLimit(1)
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
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
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
                .font(.system(size: 36))
                .foregroundStyle(SpaceSenseTheme.secondaryAccent)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(SpaceSenseTheme.slate)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
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

        let filtered = source.filter { item in
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

        switch largeFileSortOrder {
        case .sizeDesc:
            return filtered.sorted { $0.size > $1.size }
        case .unusedDesc:
            return filtered.sorted { $0.daysSinceLastOpened() > $1.daysSinceLastOpened() }
        case .nameAsc:
            return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
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
                    .foregroundStyle(SpaceSenseTheme.accent)
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
            .frame(minHeight: 160, idealHeight: 230, maxHeight: 340)

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
                .tint(SpaceSenseTheme.accent)
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 520, maxWidth: 580)
    }
}

private struct DeleteHubPreviewModal: View {
    let file: LargeFileItem
    let appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                    .resizable()
                    .frame(width: 36, height: 36)
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
                    .frame(maxHeight: 240)
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
                .frame(minHeight: 150, idealHeight: 200, maxHeight: 280)
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
        .frame(minWidth: 420, idealWidth: 520, maxWidth: 580)
    }

    private static func readSnippet(url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
