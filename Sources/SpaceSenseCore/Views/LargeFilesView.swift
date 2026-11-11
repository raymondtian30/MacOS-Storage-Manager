import SwiftUI
import AppKit
import QuickLookUI

public struct LargeFilesView: View {
    @Bindable var appState: AppState

    public enum SortField: String, CaseIterable, Identifiable {
        case sizeDesc = "Size (Largest First)"
        case sizeAsc = "Size (Smallest First)"
        case dateDesc = "Modified (Newest First)"
        case dateAsc = "Modified (Oldest First)"

        public var id: String { rawValue }
    }

    public enum DateFilter: String, CaseIterable, Identifiable {
        case any = "Any Date"
        case olderThan30Days = "Older than 30 Days"
        case olderThan90Days = "Older than 90 Days"
        case olderThan1Year = "Older than 1 Year"
        case last7Days = "Modified in Last 7 Days"

        public var id: String { rawValue }
    }

    @State private var searchQuery: String = ""
    @State private var extensionFilter: String = ""
    @State private var dateFilter: DateFilter = .any
    @State private var sortField: SortField = .sizeDesc
    @State private var selectedFileIDs: Set<String> = []
    @State private var previewingFile: LargeFileItem?
    @State private var showingTrashConfirmation: Bool = false

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        let filteredFiles = computeFilteredFiles()
        let selectedItems = filteredFiles.filter { selectedFileIDs.contains($0.id) }
        let selectedBytes = selectedItems.reduce(Int64(0)) { $0 + $1.size }

        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionHeaderBar(
                    title: "Large Files Finder",
                    subtitle: "Inspect, preview, and safely manage large files (>= \(Int(appState.largeFileThresholdMB)) MB)",
                    icon: NavigationSection.largeFiles.icon
                )

                if !selectedItems.isEmpty {
                    Button(role: .destructive) {
                        showingTrashConfirmation = true
                    } label: {
                        Label(
                            "Review & Move \(selectedItems.count) to Trash (\(ByteFormatting.string(selectedBytes)))",
                            systemImage: "trash"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SpaceSenseTheme.danger)
                }
            }

            filterBar

            SurfaceCard(padding: 0) {
                if filteredFiles.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.up.doc")
                            .font(.system(size: 38))
                            .foregroundStyle(.secondary)
                        Text(appState.latestScanResult == nil ? "Run a Storage Scan First" : "No Matching Large Files")
                            .font(.headline)
                        Text(
                            appState.latestScanResult == nil
                            ? "Scan a directory to discover files exceeding your size threshold."
                            : "Try clearing your extension or modification date filter."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(40)
                } else {
                    List(filteredFiles) { file in
                        largeFileRow(file)
                    }
                    .listStyle(.inset)
                }
            }
        }
        .padding(24)
        .sheet(item: $previewingFile) { item in
            FilePreviewModal(file: item, appState: appState)
        }
        .sheet(isPresented: $showingTrashConfirmation) {
            LargeFilesTrashConfirmationSheet(
                files: selectedItems,
                onConfirm: {
                    let urls = selectedItems.map(\.url)
                    let sizes = Dictionary(uniqueKeysWithValues: selectedItems.map { ($0.url, $0.size) })
                    Task {
                        _ = await appState.moveURLsToTrash(urls, sizes: sizes)
                        selectedFileIDs.removeAll()
                        showingTrashConfirmation = false
                    }
                },
                onCancel: {
                    showingTrashConfirmation = false
                }
            )
        }
    }

    private var filterBar: some View {
        SurfaceCard(padding: 12) {
            HStack(spacing: 10) {
                TextField("Search filename or path…", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)

                TextField("Extension (e.g. mov, dmg)", text: $extensionFilter)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 165)

                Picker("Date", selection: $dateFilter) {
                    ForEach(DateFilter.allCases) { df in
                        Text(df.rawValue).tag(df)
                    }
                }
                .controlSize(.small)
                .frame(width: 185)

                Picker("Sort", selection: $sortField) {
                    ForEach(SortField.allCases) { sf in
                        Text(sf.rawValue).tag(sf)
                    }
                }
                .controlSize(.small)
                .frame(width: 185)
            }
        }
    }

    private func largeFileRow(_ file: LargeFileItem) -> some View {
        let isSelected = selectedFileIDs.contains(file.id)
        return HStack(spacing: 12) {
            Toggle(
                "",
                isOn: Binding(
                    get: { isSelected },
                    set: { checked in
                        if checked {
                            selectedFileIDs.insert(file.id)
                        } else {
                            selectedFileIDs.remove(file.id)
                        }
                    }
                )
            )
            .toggleStyle(.checkbox)
            .labelsHidden()

            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                .resizable()
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if !file.fileExtension.isEmpty {
                        Text(file.fileExtension.uppercased())
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(file.category.color.opacity(0.18), in: Capsule())
                    }
                }
                Text(file.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if let mod = file.modificationDate {
                Text(mod.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 95, alignment: .trailing)
            }

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

    private func computeFilteredFiles() -> [LargeFileItem] {
        guard let source = appState.latestScanResult?.largeFiles else { return [] }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ext = extensionFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: ".", with: "")
        let now = Date()

        let filtered = source.filter { item in
            guard FileManager.default.fileExists(atPath: item.path) else { return false }
            if !q.isEmpty && !item.name.lowercased().contains(q) && !item.path.lowercased().contains(q) {
                return false
            }
            if !ext.isEmpty && item.fileExtension.lowercased() != ext {
                return false
            }
            if dateFilter != .any {
                guard let mod = item.modificationDate else { return false }
                let ageDays = now.timeIntervalSince(mod) / 86_400
                switch dateFilter {
                case .any: break
                case .olderThan30Days: if ageDays < 30 { return false }
                case .olderThan90Days: if ageDays < 90 { return false }
                case .olderThan1Year: if ageDays < 365 { return false }
                case .last7Days: if ageDays > 7 { return false }
                }
            }
            return true
        }

        switch sortField {
        case .sizeDesc:
            return filtered.sorted { $0.size > $1.size }
        case .sizeAsc:
            return filtered.sorted { $0.size < $1.size }
        case .dateDesc:
            return filtered.sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
        case .dateAsc:
            return filtered.sorted { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }
        }
    }
}

private struct FilePreviewModal: View {
    let file: LargeFileItem
    let appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                    .resizable()
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.headline)
                    Text(file.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Close") { dismiss() }
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Size:").foregroundStyle(.secondary)
                    Text(ByteFormatting.string(file.size)).fontWeight(.semibold)
                }
                GridRow {
                    Text("Category:").foregroundStyle(.secondary)
                    Text(file.category.rawValue)
                }
                GridRow {
                    Text("Modified:").foregroundStyle(.secondary)
                    Text(file.modificationDate?.formatted(date: .long, time: .shortened) ?? "Unknown")
                }
            }
            .font(.subheadline)

            if let image = NSImage(contentsOf: file.url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 280)
                    .frame(maxWidth: .infinity)
                    .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
            } else if ["txt", "md", "json", "log", "swift", "py", "csv", "xml", "yaml", "yml"].contains(file.fileExtension),
                      let handle = try? FileHandle(forReadingFrom: file.url),
                      let headData = try? handle.read(upToCount: 4096),
                      let snippet = String(data: headData, encoding: .utf8) {
                ScrollView {
                    Text(snippet)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 220)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Button("Reveal in Finder") {
                    appState.revealInFinder(file.url)
                }
                Button("Open in Default App") {
                    appState.openFile(file.url)
                }
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

private struct LargeFilesTrashConfirmationSheet: View {
    let files: [LargeFileItem]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "trash.circle.fill")
                    .font(.title)
                    .foregroundStyle(SpaceSenseTheme.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Move \(files.count) Selected File(s) to Trash?")
                        .font(.headline)
                    Text("Total size: \(ByteFormatting.string(total)). Items are moved to macOS Trash and are not permanently deleted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            List(files) { item in
                HStack {
                    Text(item.name)
                        .font(.caption.weight(.medium))
                    Spacer()
                    Text(ByteFormatting.string(item.size))
                        .font(.caption.monospacedDigit())
                }
            }
            .frame(height: 200)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Move to Trash", role: .destructive, action: onConfirm)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}
