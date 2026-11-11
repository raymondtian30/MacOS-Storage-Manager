import SwiftUI

@MainActor
@Observable
final class AnalyzerHoverState {
    var hoveredNodeID: String?
}

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
    @State private var hoverState = AnalyzerHoverState()

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        GeometryReader { geo in
            let isCompact = geo.size.width < 720
            let useVerticalSplit = geo.size.width < 620 && geo.size.height >= 540
            VStack(alignment: .leading, spacing: 12) {
                topBar

                if let currentNode = appState.analyzerCurrentNode {
                    let visibleChildren = filteredAndSortedChildren(for: currentNode)
                    breadcrumbBar(currentNode: currentNode)

                    if useVerticalSplit {
                        VSplitView {
                            treemapPanel(items: visibleChildren)
                                .frame(minHeight: 110, maxHeight: .infinity)
                            directoryListPanel(for: currentNode, children: visibleChildren)
                                .frame(minHeight: 120, maxHeight: .infinity)
                        }
                    } else {
                        HSplitView {
                            treemapPanel(items: visibleChildren)
                                .frame(minWidth: 190, maxWidth: .infinity, maxHeight: .infinity)

                            directoryListPanel(for: currentNode, children: visibleChildren)
                                .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                } else {
                    emptyAnalyzerState
                }
            }
            .padding(isCompact ? 14 : 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                SectionHeaderBar(
                    title: "Storage Analyzer",
                    subtitle: "Interactive treemap and folder hierarchy inspector",
                    icon: NavigationSection.analyzer.icon
                )
                analyzerActionButtons
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionHeaderBar(
                    title: "Storage Analyzer",
                    subtitle: "Interactive treemap and folder hierarchy inspector",
                    icon: NavigationSection.analyzer.icon
                )
                analyzerActionButtons
            }
        }
    }

    private var analyzerActionButtons: some View {
        HStack(spacing: 8) {
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
                    .lineLimit(1)
            }
            .buttonStyle(.borderedProminent)
            .tint(SpaceSenseTheme.accent)
        }
    }

    private func breadcrumbBar(currentNode: FileNode) -> some View {
        SurfaceCard(padding: 8) {
            HStack(spacing: 8) {
                Button {
                    appState.navigateBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(appState.analyzerBreadcrumbs.count <= 1)
                .help("Navigate Back")

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
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(crumb.id == currentNode.id ? SpaceSenseTheme.accent.opacity(0.16) : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    Text(ByteFormatting.string(currentNode.size))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(SpaceSenseTheme.slate)
                        .lineLimit(1)
                    InfoTooltipIcon("Allocated size measures physical 4 KB blocks reserved on your APFS volume rather than logical byte length.")
                }

                Button {
                    appState.revealInFinder(currentNode.url)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reveal Current Folder in Finder")
            }
        }
    }

    private func treemapPanel(items: [FileNode]) -> some View {
        SurfaceCard(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Storage Treemap")
                        .font(.headline)
                        .lineLimit(1)
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
                        hoverState: hoverState
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

    private func directoryListPanel(for node: FileNode, children: [FileNode]) -> some View {
        let parentTotal = max(node.size, 1)

        return SurfaceCard(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        filterControls
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            TextField("Search…", text: $searchText)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)
                            TextField("Ext", text: $fileTypeFilter)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)
                                .frame(width: 65)
                        }
                        HStack(spacing: 6) {
                            categoryAndSortPickers
                        }
                    }
                }

                List(children) { item in
                    AnalyzerDirectoryRowView(
                        item: item,
                        parentTotal: parentTotal,
                        hoverState: hoverState,
                        appState: appState
                    )
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private var filterControls: some View {
        TextField("Search…", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(minWidth: 80)

        TextField("Ext", text: $fileTypeFilter)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(width: 64)

        categoryAndSortPickers
    }

    @ViewBuilder
    private var categoryAndSortPickers: some View {
        Picker("Category", selection: $appState.analyzerCategoryFilter) {
            Text("All Categories").tag(StorageCategory?.none)
            ForEach(StorageCategory.allCases) { cat in
                Text(cat.rawValue).tag(StorageCategory?.some(cat))
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .frame(minWidth: 105, maxWidth: 140)

        Picker("Sort", selection: $sortOrder) {
            ForEach(SortOrder.allCases) { order in
                Text(order.rawValue).tag(order)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .frame(minWidth: 105, maxWidth: 135)
    }

    private var emptyAnalyzerState: some View {
        SurfaceCard {
            VStack(spacing: 14) {
                Image(systemName: "externaldrive.badge.magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(SpaceSenseTheme.accent)
                Text("Ready to Analyze Your Storage")
                    .font(.title3.weight(.semibold))
                Text("Select a folder or scan your Home directory to calculate folder sizes and explore the interactive treemap.")
                    .font(.subheadline)
                    .foregroundStyle(SpaceSenseTheme.slate)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
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
            .padding(24)
        }
    }

    private func filteredAndSortedChildren(for node: FileNode) -> [FileNode] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedExt = fileTypeFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: ".", with: "")
        let categoryFilter = appState.analyzerCategoryFilter

        let hasFilters = (categoryFilter != nil) || !trimmedExt.isEmpty || !trimmedSearch.isEmpty
        if !hasFilters && sortOrder == .sizeDesc {
            return node.children
        }

        let filtered: [FileNode]
        if hasFilters {
            filtered = node.children.filter { child in
                if let cat = categoryFilter, child.category != cat && !child.isDirectory {
                    return false
                }
                if !trimmedExt.isEmpty && !child.isDirectory && child.fileExtension != trimmedExt {
                    return false
                }
                if !trimmedSearch.isEmpty {
                    let matchesName = child.name.lowercased().contains(trimmedSearch)
                    let matchesPath = child.id.lowercased().contains(trimmedSearch)
                    if !matchesName && !matchesPath {
                        return false
                    }
                }
                return true
            }
        } else {
            filtered = node.children
        }

        switch sortOrder {
        case .sizeDesc:
            return filtered
        case .modifiedDesc:
            return filtered.sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
        case .nameAsc:
            return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
}

private struct AnalyzerDirectoryRowView: View {
    let item: FileNode
    let parentTotal: Int64
    let hoverState: AnalyzerHoverState
    let appState: AppState

    var body: some View {
        let isHovered = hoverState.hoveredNodeID == item.id
        let fraction = CGFloat(min(1.0, max(0.0, Double(item.size) / Double(parentTotal))))
        let barColor = item.isDirectory ? SpaceSenseTheme.accent : SpaceSenseTheme.secondaryAccent

        HStack(spacing: 8) {
            Image(systemName: item.isDirectory ? "folder.fill" : item.category.icon)
                .foregroundStyle(barColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    if !item.isAccessible {
                        Text("Restricted")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(SpaceSenseTheme.slate.opacity(0.2), in: Capsule())
                    }
                }
                Text(item.id)
                    .font(.caption2)
                    .foregroundStyle(SpaceSenseTheme.slate)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.id)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 3) {
                Text(ByteFormatting.string(item.size))
                    .font(.caption.monospacedDigit().weight(.semibold))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(SpaceSenseTheme.slate.opacity(0.18))
                        .frame(width: 56, height: 5)
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(fraction > 0 ? 3 : 0, 56 * fraction), height: 5)
                }
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
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? SpaceSenseTheme.accent.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                if hoverState.hoveredNodeID != item.id {
                    hoverState.hoveredNodeID = item.id
                }
            } else if hoverState.hoveredNodeID == item.id {
                hoverState.hoveredNodeID = nil
            }
        }
        .onTapGesture {
            if item.isDirectory && !item.children.isEmpty {
                appState.drillDown(to: item)
            } else {
                appState.revealInFinder(item.url)
            }
        }
        .contextMenu {
            if item.isDirectory && !item.children.isEmpty {
                Button("Inspect Subfolder") { appState.drillDown(to: item) }
            }
            Button("Reveal in Finder") { appState.revealInFinder(item.url) }
            Button("Open") { appState.openFile(item.url) }
            Button("Copy Path") { appState.copyPathToClipboard(item.id) }
        }
    }
}

public struct SquarifiedTreemapView: View {
    public let items: [FileNode]
    @Binding public var hoveredID: String?
    private let hoverState: AnalyzerHoverState?
    public let onSelect: (FileNode) -> Void

    public init(
        items: [FileNode],
        hoveredID: Binding<String?>,
        onSelect: @escaping (FileNode) -> Void
    ) {
        self.items = items
        self._hoveredID = hoveredID
        self.hoverState = nil
        self.onSelect = onSelect
    }

    init(
        items: [FileNode],
        hoverState: AnalyzerHoverState,
        onSelect: @escaping (FileNode) -> Void
    ) {
        self.items = items
        self._hoveredID = .constant(nil)
        self.hoverState = hoverState
        self.onSelect = onSelect
    }

    public var body: some View {
        GeometryReader { geo in
            let rects = computeTreemapRects(items: items, in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(rects, id: \.node.id) { entry in
                    TreemapCellView(
                        node: entry.node,
                        rect: entry.rect,
                        hoverState: hoverState,
                        hoveredIDBinding: $hoveredID,
                        onSelect: onSelect
                    )
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
        var output: [LayoutEntry] = []
        output.reserveCapacity(positive.count)
        sliceAndDice(positive[...], in: bounds, horizontal: bounds.width >= bounds.height, into: &output)
        return output
    }

    private func sliceAndDice(
        _ nodes: ArraySlice<FileNode>,
        in rect: CGRect,
        horizontal: Bool,
        into output: inout [LayoutEntry]
    ) {
        guard !nodes.isEmpty, rect.width > 2, rect.height > 2 else { return }
        if nodes.count == 1, let first = nodes.first {
            output.append(LayoutEntry(node: first, rect: rect))
            return
        }

        var total: Int64 = 0
        for node in nodes {
            total += max(node.size, 1)
        }
        guard total > 0 else { return }

        var running: Int64 = 0
        var leftSum: Int64 = 0
        var splitIndex = nodes.startIndex + 1
        let half = total / 2

        for idx in nodes.indices {
            let weight = max(nodes[idx].size, 1)
            running += weight
            if running >= half {
                if idx < nodes.endIndex - 1 {
                    splitIndex = idx + 1
                    leftSum = running
                } else {
                    splitIndex = nodes.endIndex - 1
                    leftSum = running - weight
                }
                break
            }
        }

        let leftNodes = nodes[nodes.startIndex..<splitIndex]
        let rightNodes = nodes[splitIndex..<nodes.endIndex]
        let ratio = CGFloat(Double(leftSum) / Double(total))

        if horizontal {
            let leftWidth = rect.width * ratio
            let r1 = CGRect(x: rect.minX, y: rect.minY, width: leftWidth, height: rect.height)
            let r2 = CGRect(x: rect.minX + leftWidth, y: rect.minY, width: max(0, rect.width - leftWidth), height: rect.height)
            sliceAndDice(leftNodes, in: r1, horizontal: !horizontal, into: &output)
            sliceAndDice(rightNodes, in: r2, horizontal: !horizontal, into: &output)
        } else {
            let topHeight = rect.height * ratio
            let r1 = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: topHeight)
            let r2 = CGRect(x: rect.minX, y: rect.minY + topHeight, width: rect.width, height: max(0, rect.height - topHeight))
            sliceAndDice(leftNodes, in: r1, horizontal: !horizontal, into: &output)
            sliceAndDice(rightNodes, in: r2, horizontal: !horizontal, into: &output)
        }
    }
}

private struct TreemapCellView: View {
    let node: FileNode
    let rect: CGRect
    let hoverState: AnalyzerHoverState?
    @Binding var hoveredIDBinding: String?
    let onSelect: (FileNode) -> Void

    var body: some View {
        let isHovered = (hoverState?.hoveredNodeID ?? hoveredIDBinding) == node.id
        let baseColor = node.isDirectory ? SpaceSenseTheme.accent : SpaceSenseTheme.secondaryAccent
        let formattedSize = ByteFormatting.string(node.size)

        Button {
            onSelect(node)
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

                if rect.width > 46 && rect.height > 28 {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 3) {
                            Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                                .font(.caption2)
                            Text(node.name)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        if rect.height > 40 {
                            Text(formattedSize)
                                .font(.caption2.monospacedDigit())
                                .opacity(0.9)
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(4)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: max(0, rect.width - 2), height: max(0, rect.height - 2))
        .position(x: rect.midX, y: rect.midY)
        .onHover { hovering in
            if let hoverState {
                if hovering {
                    if hoverState.hoveredNodeID != node.id {
                        hoverState.hoveredNodeID = node.id
                    }
                } else if hoverState.hoveredNodeID == node.id {
                    hoverState.hoveredNodeID = nil
                }
            } else {
                if hovering {
                    hoveredIDBinding = node.id
                } else if hoveredIDBinding == node.id {
                    hoveredIDBinding = nil
                }
            }
        }
        .help("\(node.name) — \(formattedSize)")
    }
}
