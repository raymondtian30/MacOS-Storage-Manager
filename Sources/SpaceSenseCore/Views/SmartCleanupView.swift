import SwiftUI

public struct SmartCleanupView: View {
    @Bindable var appState: AppState
    @State private var selectedKindFilter: CleanupKind?
    @State private var showingReviewSheet: Bool = false

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        let filtered = filteredCandidates()
        let selectedCandidates = filtered.filter(\.isSelected)
        let selectedBytes = selectedCandidates.reduce(Int64(0)) { $0 + $1.sizeBytes }

        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionHeaderBar(
                    title: "Smart Cleanup",
                    subtitle: "Reviewable, non-destructive recommendations — items are always moved to macOS Trash",
                    icon: NavigationSection.smartCleanup.icon
                )

                Button {
                    appState.rebuildCleanupRecommendations()
                } label: {
                    Label("Refresh Candidates", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)

                Button {
                    showingReviewSheet = true
                } label: {
                    Label(
                        "Review & Move \(selectedCandidates.count) to Trash (\(ByteFormatting.string(selectedBytes)))",
                        systemImage: "trash.fill"
                    )
                    .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(SpaceSenseTheme.secondaryAccent)
                .disabled(selectedCandidates.isEmpty)
            }

            filterPillsBar

            SurfaceCard(padding: 0) {
                if filtered.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(SpaceSenseTheme.secondaryAccent)
                        Text("No Cleanup Candidates in This Category")
                            .font(.headline)
                        Text("Run a Storage Scan or System Data analysis to identify old installers, caches, build artifacts, and duplicate files.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 440)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(40)
                } else {
                    List {
                        ForEach(filtered) { candidate in
                            candidateCardRow(candidate)
                        }
                    }
                    .listStyle(.inset)
                }
            }
        }
        .padding(24)
        .sheet(isPresented: $showingReviewSheet) {
            SmartCleanupReviewSheet(
                candidates: selectedCandidates,
                onConfirm: {
                    let urls = selectedCandidates.map(\.locationURL)
                    let sizes = Dictionary(uniqueKeysWithValues: selectedCandidates.map { ($0.locationURL, $0.sizeBytes) })
                    Task {
                        _ = await appState.moveURLsToTrash(urls, sizes: sizes)
                        showingReviewSheet = false
                    }
                },
                onCancel: {
                    showingReviewSheet = false
                }
            )
        }
    }

    private var filterPillsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    selectedKindFilter = nil
                } label: {
                    Text("All (\(appState.cleanupCandidates.count))")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(selectedKindFilter == nil ? SpaceSenseTheme.accent : Color.primary.opacity(0.08))
                        )
                        .foregroundStyle(selectedKindFilter == nil ? .white : .primary)
                }
                .buttonStyle(.plain)

                ForEach(CleanupKind.allCases) { kind in
                    let count = appState.cleanupCandidates.filter { $0.kind == kind }.count
                    Button {
                        selectedKindFilter = kind
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: kind.icon)
                            Text("\(kind.rawValue) (\(count))")
                        }
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(selectedKindFilter == kind ? SpaceSenseTheme.accent : Color.primary.opacity(0.08))
                        )
                        .foregroundStyle(selectedKindFilter == kind ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func candidateCardRow(_ candidate: CleanupCandidate) -> some View {
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
                .frame(width: 28)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(candidate.title)
                        .font(.subheadline.weight(.bold))

                    Text(candidate.kind.rawValue)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08), in: Capsule())

                    Text(candidate.risk.rawValue)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(candidate.risk.color.opacity(0.18), in: Capsule())
                        .foregroundStyle(candidate.risk.color)
                }

                // All 5 required cleanup explanation items:
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow {
                        Text("1. What will be removed:")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(candidate.whatWillBeRemoved)
                            .font(.caption)
                    }
                    GridRow {
                        Text("2. Location:")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(candidate.locationURL.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    GridRow {
                        Text("3. Storage occupied:")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(ByteFormatting.string(candidate.sizeBytes))
                            .font(.caption.monospacedDigit().weight(.bold))
                    }
                    GridRow {
                        Text("4. Why recommended:")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(candidate.whyRecommended)
                            .font(.caption)
                    }
                    GridRow {
                        Text("5. Potential consequences:")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(candidate.potentialConsequences)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
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
        .padding(.vertical, 8)
    }

    private func filteredCandidates() -> [CleanupCandidate] {
        guard let kind = selectedKindFilter else {
            return appState.cleanupCandidates
        }
        return appState.cleanupCandidates.filter { $0.kind == kind }
    }
}

private struct SmartCleanupReviewSheet: View {
    let candidates: [CleanupCandidate]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let total = candidates.reduce(Int64(0)) { $0 + $1.sizeBytes }
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.title)
                    .foregroundStyle(SpaceSenseTheme.secondaryAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Confirm Smart Cleanup — Move \(candidates.count) Item(s) to Trash")
                        .font(.headline)
                    Text("SpaceSense will move these items (\(ByteFormatting.string(total))) to your macOS Trash. Nothing is permanently deleted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            List(candidates) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(item.title)
                            .font(.caption.weight(.bold))
                        Spacer()
                        Text(ByteFormatting.string(item.sizeBytes))
                            .font(.caption.monospacedDigit().weight(.semibold))
                    }
                    Text("Location: \(item.locationURL.path)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Text("Consequence: \(item.potentialConsequences)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .frame(height: 240)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Move Selected Items to Trash", role: .destructive, action: onConfirm)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
