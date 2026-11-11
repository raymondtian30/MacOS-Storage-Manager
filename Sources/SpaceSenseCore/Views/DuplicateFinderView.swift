import SwiftUI
import AppKit

public struct DuplicateFinderView: View {
    @Bindable var appState: AppState
    @State private var searchFilter: String = ""
    @State private var showingConfirmation: Bool = false

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        let groups = filteredGroups()
        let totalReclaimable = appState.duplicateGroups.reduce(Int64(0)) { $0 + $1.reclaimableBytes }
        let selectedFiles = groups.flatMap { $0.files.filter(\.isMarkedForRemoval) }
        let selectedBytes = selectedFiles.reduce(Int64(0)) { $0 + $1.size }

        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                SectionHeaderBar(
                    title: "Duplicate Finder",
                    subtitle: "Cryptographic SHA-256 duplicate detection (at least one copy per group is always preserved)",
                    icon: NavigationSection.duplicates.icon
                )

                Button {
                    Task { await appState.runDuplicateScan() }
                } label: {
                    Label(
                        appState.isFindingDuplicates ? "Hashing…" : "Re-scan Duplicates",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(appState.isFindingDuplicates || appState.latestScanResult == nil)

                if !selectedFiles.isEmpty {
                    Button(role: .destructive) {
                        showingConfirmation = true
                    } label: {
                        Label(
                            "Review & Trash \(selectedFiles.count) Copies (\(ByteFormatting.string(selectedBytes)))",
                            systemImage: "trash"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SpaceSenseTheme.danger)
                }
            }

            summaryAndControlsBar(totalReclaimable: totalReclaimable, selectedBytes: selectedBytes)

            if appState.isFindingDuplicates {
                SurfaceCard(padding: 12) {
                    HStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Computing SHA-256 digests via Apple CryptoKit (\(appState.duplicateProgress.processed) / \(appState.duplicateProgress.total) candidate files)…")
                            .font(.caption)
                        Spacer()
                        Button(role: .cancel) {
                            appState.cancelDuplicateScan()
                        } label: {
                            Label("Cancel", systemImage: "xmark.circle.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            SurfaceCard(padding: 0) {
                if groups.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 38))
                            .foregroundStyle(.secondary)
                        Text(appState.latestScanResult == nil ? "Run a Storage Scan First" : "No Exact Duplicate Files Found")
                            .font(.headline)
                        Text(
                            appState.latestScanResult == nil
                            ? "Scan a directory first so SpaceSense can group same-size files and verify exact duplicates with SHA-256."
                            : "No byte-identical files above \(String(format: "%.1f", appState.duplicateMinimumSizeMB)) MB were detected in the scanned folder."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(40)
                } else {
                    List {
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.files) { file in
                                    duplicateRow(group: group, file: file)
                                }
                            } header: {
                                HStack {
                                    Label(
                                        "\(group.files.count) identical copies • \(ByteFormatting.string(group.fileSize)) each",
                                        systemImage: "number.square.fill"
                                    )
                                    .font(.caption.weight(.bold))
                                    Text("SHA-256: \(String(group.sha256Hash.prefix(16)))…")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("Reclaimable: \(ByteFormatting.string(group.reclaimableBytes))")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(SpaceSenseTheme.secondaryAccent)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
        }
        .padding(24)
        .sheet(isPresented: $showingConfirmation) {
            DuplicateTrashConfirmationSheet(
                files: selectedFiles,
                onConfirm: {
                    let urls = selectedFiles.map(\.url)
                    let sizes = Dictionary(uniqueKeysWithValues: selectedFiles.map { ($0.url, $0.size) })
                    Task {
                        _ = await appState.moveURLsToTrash(urls, sizes: sizes)
                        showingConfirmation = false
                    }
                },
                onCancel: {
                    showingConfirmation = false
                }
            )
        }
    }

    private func summaryAndControlsBar(totalReclaimable: Int64, selectedBytes: Int64) -> some View {
        SurfaceCard(padding: 12) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Duplicate Groups: \(appState.duplicateGroups.count)")
                        .font(.subheadline.weight(.semibold))
                    Text("Total Reclaimable: \(ByteFormatting.string(totalReclaimable)) • Selected: \(ByteFormatting.string(selectedBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                TextField("Filter by filename or path…", text: $searchFilter)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 220)

                HStack(spacing: 6) {
                    Text("Min Size:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Min Size", selection: $appState.duplicateMinimumSizeMB) {
                        Text("100 KB").tag(0.1)
                        Text("1 MB").tag(1.0)
                        Text("10 MB").tag(10.0)
                        Text("50 MB").tag(50.0)
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 95)
                    .onChange(of: appState.duplicateMinimumSizeMB) { _, _ in
                        Task { await appState.runDuplicateScan() }
                    }
                }
            }
        }
    }

    private func duplicateRow(group: DuplicateGroup, file: DuplicateFileItem) -> some View {
        HStack(spacing: 12) {
            Button {
                appState.toggleDuplicateSelection(groupID: group.id, fileID: file.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: file.isMarkedForRemoval ? "trash.circle.fill" : "shield.lefthalf.filled")
                        .foregroundStyle(file.isMarkedForRemoval ? SpaceSenseTheme.danger : SpaceSenseTheme.secondaryAccent)
                    Text(file.isMarkedForRemoval ? "Move to Trash" : "Keep Copy")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill((file.isMarkedForRemoval ? SpaceSenseTheme.danger : SpaceSenseTheme.secondaryAccent).opacity(0.15))
                )
            }
            .buttonStyle(.plain)
            .frame(width: 120, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.subheadline.weight(.medium))
                Text(file.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if let mod = file.modificationDate {
                Text("Modified \(mod.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(ByteFormatting.string(file.size))
                .font(.caption.monospacedDigit().weight(.semibold))

            Button {
                appState.revealInFinder(file.url)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Reveal in Finder")
        }
        .padding(.vertical, 3)
    }

    private func filteredGroups() -> [DuplicateGroup] {
        let q = searchFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return appState.duplicateGroups }
        return appState.duplicateGroups.filter { group in
            group.files.contains {
                $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q)
            }
        }
    }

    private func selectedDuplicateFiles() -> [DuplicateFileItem] {
        appState.duplicateGroups.flatMap { group in
            group.files.filter(\.isMarkedForRemoval)
        }
    }
}

private struct DuplicateTrashConfirmationSheet: View {
    let files: [DuplicateFileItem]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "doc.on.doc.fill")
                    .font(.title)
                    .foregroundStyle(SpaceSenseTheme.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Move \(files.count) Duplicate Copy(s) to Trash?")
                        .font(.headline)
                    Text("Reclaims \(ByteFormatting.string(total)). At least one verified SHA-256 original copy of each file remains untouched.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            List(files) { file in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(file.name).font(.caption.weight(.semibold))
                        Spacer()
                        Text(ByteFormatting.string(file.size)).font(.caption.monospacedDigit())
                    }
                    Text(file.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(height: 220)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Move Duplicates to Trash", role: .destructive, action: onConfirm)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
