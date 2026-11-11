import SwiftUI

public struct StorageAnalyzerView: View {
    @Bindable var appState: AppState

    public enum SortOrder: String, CaseIterable, Identifiable {
        case sizeDesc = "Largest First"
        case modifiedDesc = "Recently Modified"
        case nameAsc = "Name (A–Z)"

        public var id: String { rawValue }
    }

    @State private var sortOrder: SortOrder = .sizeDesc
    @State private var fileTypeFilter: String = ""
    @State private var searchText: String = ""
    @State private var hoveredNodeID: String?

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            topBar

            if let currentNode = appState.analyzerCurrentNode {
                breadcrumbBar(currentNode: currentNode)

                HSplitView {
                    treemapPanel(for: currentNode)
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)

                    directoryListPanel(for: currentNode)
                        .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                emptyAnalyzerState
            }
        }
        .padding(24)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            SectionHeaderBar(
                title: "Storage Analyzer",
                subtitle: "Interactive treemap and folder hierarchy inspector",
                icon: NavigationSection.analyzer.icon
            )

            Button {
                appState.chooseDirectoryAndScan()
            } label: {
                Label("Choose Folder…", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.bordered)

            Button {
                appState.requestStartScan(at: appState.selectedScanRoot)
            } label: {
                Label("Scan \(appState.selectedScanRoot.lastPathComponent)", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .tint(SpaceSenseTheme.accent)
        }
    }

    private func breadcrumbBar(currentNode: FileNode) -> some View {
        SurfaceCard(padding: 10) {
            HStack(spacing: 8) {
                Button {
                    appState.navigateBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(appState.analyzerBreadcrumbs.count <= 1)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(appState.analyzerBreadcrumbs.enumerated()), id: \.element.id) { idx, crumb in
                            if idx > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(SpaceSenseTheme.slate)
                            }
                            Button {
                                appState.drillDown(to: crumb)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(SpaceSenseTheme.accent)
                                    Text(crumb.name)
                                        .font(.caption.weight(crumb.id == currentNode.id ? .bold : .regular))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(crumb.id == currentNode.id ? SpaceSenseTheme.accent.opacity(0.16) : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Spacer()

                HStack(spacing: 4) {
                    Text("Allocated Size: \(ByteFormatting.string(currentNode.size))")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(SpaceSenseTheme.slate)
                    InfoTooltipIcon("Allocated size measures physical 4 KB blocks reserved on your APFS volume rather than logical byte length.")
                }

                Button {
                    appState.revealInFinder(currentNode.url)
                } label: {
                    Label("Reveal", systemImage: "folder")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func treemapPanel(for node: FileNode) -> some View {
        let items = filteredAndSortedChildren(for: node)
        return SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Storage Treemap")
                        .font(.headline)
                    InfoTooltipIcon("Each block's area is proportional to its physical disk footprint inside the current folder. Click a folder block to drill down.")
                    Spacer()
                }

                if items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "square.dashed")
                            .font(.largeTitle)
                            .foregroundStyle(SpaceSenseTheme.slate)
                        Text("No matching items in this folder.")
                            .font(.caption)
                            .foregroundStyle(SpaceSenseTheme.slate)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    SquarifiedTreemapView(
                        items: Array(items.prefix(28)),
                        hoveredID: $hoveredNodeID
                    ) { tapped in
                        if tapped.isDirectory && !tapped.children.isEmpty {
                            appState.drillDown(to: tapped)
                        } else {
                            appState.revealInFinder(tapped.url)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func directoryListPanel(for node: FileNode) -> some View {
        let children = filteredAndSortedChildren(for: node)
        let parentTotal = max(node.size, 1)

        return SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField("Search name or path…", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)

                    TextField("Ext (e.g. dmg)", text: $fileTypeFilter)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 95)

                    Picker("Category", selection: $appState.analyzerCategoryFilter) {
                        Text("All Categories").tag(StorageCategory?.none)
                        ForEach(StorageCategory.allCases) { cat in
                            Text(cat.rawValue).tag(StorageCategory?.some(cat))
                        }
                    }
                    .controlSize(.small)
                    .frame(width: 145)

                    Picker("Sort", selection: $sortOrder) {
                        ForEach(SortOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    .controlSize(.small)
                    .frame(width: 145)
                }

                List(children) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.isDirectory ? "folder.fill" : item.category.icon)
                            .foregroundStyle(item.isDirectory ? SpaceSenseTheme.accent : SpaceSenseTheme.secondaryAccent)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(item.name)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                if !item.isAccessible {
                                    Text("Restricted")
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(SpaceSenseTheme.slate.opacity(0.2), in: Capsule())
                                }
                            }
                            HStack(spacing: 8) {
                                Text(item.url.path)
                                    .font(.caption2)
                                    .foregroundStyle(SpaceSenseTheme.slate)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if let mod = item.modificationDate {
                                    Text("• \(mod.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption2)
                                        .foregroundStyle(SpaceSenseTheme.slate)
                                }
                            }
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 3) {
                            Text(ByteFormatting.string(item.size))
                                .font(.caption.monospacedDigit().weight(.semibold))
                            ProgressView(value: min(1.0, max(0.0, Double(item.size) / Double(parentTotal))))
                                .tint(item.isDirectory ? SpaceSenseTheme.accent : SpaceSenseTheme.secondaryAccent)
                                .frame(width: 70)
                        }

                        if item.isDirectory && !item.children.isEmpty {
                            Button {
                                appState.drillDown(to: item)
                            } label: {
                                Image(systemName: "arrow.right.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .help("Inspect Subfolder")
                        }

                        Button {
                            appState.revealInFinder(item.url)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .help("Reveal in Finder")
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        if item.isDirectory && !item.children.isEmpty {
                            appState.drillDown(to: item)
                        } else {
                            appState.revealInFinder(item.url)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var emptyAnalyzerState: some View {
        SurfaceCard {
            VStack(spacing: 14) {
                Image(systemName: "externaldrive.badge.magnifyingglass")
                    .font(.system(size: 44))
                    .foregroundStyle(SpaceSenseTheme.accent)
                Text("Ready to Analyze Your Storage")
                    .font(.title3.weight(.semibold))
                Text("Select a folder or scan your Home directory to calculate folder sizes and explore the interactive treemap.")
                    .font(.subheadline)
                    .foregroundStyle(SpaceSenseTheme.slate)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                HStack(spacing: 12) {
                    Button("Choose Folder…") {
                        appState.chooseDirectoryAndScan()
                    }
                    .buttonStyle(.bordered)

                    Button("Scan Home Directory") {
                        appState.requestStartScan(at: FileManager.default.homeDirectoryForCurrentUser)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SpaceSenseTheme.accent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        }
    }

    private func filteredAndSortedChildren(for node: FileNode) -> [FileNode] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedExt = fileTypeFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: ".", with: "")

        let filtered = node.children.filter { child in
            if let cat = appState.analyzerCategoryFilter, child.category != cat && !child.isDirectory {
                return false
            }
            if !trimmedExt.isEmpty && !child.isDirectory && child.fileExtension.lowercased() != trimmedExt {
                return false
            }
            if !trimmedSearch.isEmpty {
                let matchesName = child.name.lowercased().contains(trimmedSearch)
                let matchesPath = child.url.path.lowercased().contains(trimmedSearch)
                if !matchesName && !matchesPath {
                    return false
                }
            }
            return true
        }

        switch sortOrder {
        case .sizeDesc:
            return filtered.sorted { $0.size > $1.size }
        case .modifiedDesc:
            return filtered.sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
        case .nameAsc:
            return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
}

public struct SquarifiedTreemapView: View {
    public let items: [FileNode]
    @Binding public var hoveredID: String?
    public let onSelect: (FileNode) -> Void

    public init(
        items: [FileNode],
        hoveredID: Binding<String?>,
        onSelect: @escaping (FileNode) -> Void
    ) {
        self.items = items
        self._hoveredID = hoveredID
        self.onSelect = onSelect
    }

    public var body: some View {
        GeometryReader { geo in
            let rects = computeTreemapRects(items: items, in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(rects, id: \.node.id) { entry in
                    let isHovered = hoveredID == entry.node.id
                    let baseColor = entry.node.isDirectory ? SpaceSenseTheme.accent : SpaceSenseTheme.secondaryAccent
                    Button {
                        onSelect(entry.node)
                    } label: {
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            baseColor.opacity(isHovered ? 0.88 : 0.68),
                                            baseColor.opacity(isHovered ? 0.62 : 0.42)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color.white.opacity(isHovered ? 0.65 : 0.16), lineWidth: isHovered ? 1.5 : 1)

                            if entry.rect.width > 58 && entry.rect.height > 36 {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Image(systemName: entry.node.isDirectory ? "folder.fill" : "doc.fill")
                                            .font(.caption2)
                                        Text(entry.node.name)
                                            .font(.caption.weight(.semibold))
                                            .lineLimit(1)
                                    }
                                    Text(ByteFormatting.string(entry.node.size))
                                        .font(.caption2.monospacedDigit())
                                        .opacity(0.9)
                                }
                                .foregroundStyle(.white)
                                .padding(6)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(width: max(0, entry.rect.width - 3), height: max(0, entry.rect.height - 3))
                    .position(x: entry.rect.midX, y: entry.rect.midY)
                    .onHover { hovering in
                        if hovering {
                            hoveredID = entry.node.id
                        } else if hoveredID == entry.node.id {
                            hoveredID = nil
                        }
                    }
                    .help("\(entry.node.name) — \(ByteFormatting.string(entry.node.size))")
                }
            }
        }
    }

    private struct LayoutEntry {
        let node: FileNode
        let rect: CGRect
    }

    private func computeTreemapRects(items: [FileNode], in bounds: CGRect) -> [LayoutEntry] {
        let positive = items.filter { $0.size > 0 }
        guard !positive.isEmpty, bounds.width > 10, bounds.height > 10 else { return [] }
        return sliceAndDice(positive, in: bounds, horizontal: bounds.width >= bounds.height)
    }

    private func sliceAndDice(_ nodes: [FileNode], in rect: CGRect, horizontal: Bool) -> [LayoutEntry] {
        guard !nodes.isEmpty else { return [] }
        if nodes.count == 1 {
            return [LayoutEntry(node: nodes[0], rect: rect)]
        }

        let total = nodes.reduce(Int64(0)) { $0 + max($1.size, 1) }
        guard total > 0 else { return [] }

        var running: Int64 = 0
        var splitIndex = 1
        let half = total / 2
        for (idx, node) in nodes.enumerated() {
            running += max(node.size, 1)
            if running >= half {
                splitIndex = max(1, min(nodes.count - 1, idx + 1))
                break
            }
        }

        let leftNodes = Array(nodes[0..<splitIndex])
        let rightNodes = Array(nodes[splitIndex..<nodes.count])
        let leftSum = leftNodes.reduce(Int64(0)) { $0 + max($1.size, 1) }
        let ratio = CGFloat(Double(leftSum) / Double(total))

        if horizontal {
            let leftWidth = min(rect.width, max(4, rect.width * ratio))
            let r1 = CGRect(x: rect.minX, y: rect.minY, width: leftWidth, height: rect.height)
            let r2 = CGRect(x: rect.minX + leftWidth, y: rect.minY, width: max(0, rect.width - leftWidth), height: rect.height)
            return sliceAndDice(leftNodes, in: r1, horizontal: !horizontal)
                + sliceAndDice(rightNodes, in: r2, horizontal: !horizontal)
        } else {
            let topHeight = min(rect.height, max(4, rect.height * ratio))
            let r1 = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: topHeight)
            let r2 = CGRect(x: rect.minX, y: rect.minY + topHeight, width: rect.width, height: max(0, rect.height - topHeight))
            return sliceAndDice(leftNodes, in: r1, horizontal: !horizontal)
                + sliceAndDice(rightNodes, in: r2, horizontal: !horizontal)
        }
    }
}
