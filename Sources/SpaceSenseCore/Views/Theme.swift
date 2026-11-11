import SwiftUI

/// Sleek 3-color palette:
/// 1. Electric Cyan (`accent`) — primary actions, active navigation, primary data
/// 2. Emerald Mint (`secondaryAccent`) — available/reclaimable space, safe badges, preserved copies
/// 3. Cool Slate (`slate`) — neutral surfaces, borders, secondary labels, muted states
public enum SpaceSenseTheme {
    public static let accent = Color(red: 0.22, green: 0.68, blue: 0.96)
    public static let secondaryAccent = Color(red: 0.20, green: 0.82, blue: 0.64)
    public static let slate = Color(red: 0.46, green: 0.54, blue: 0.66)
    public static let warning = Color(red: 0.22, green: 0.68, blue: 0.96)
    public static let danger = Color(red: 0.46, green: 0.54, blue: 0.66)
}

/// Hoverable question-mark icon used strictly next to technical or non-obvious storage concepts.
public struct InfoTooltipIcon: View {
    public let explanation: String
    @State private var isShowingPopover: Bool = false
    @State private var dismissWorkItem: DispatchWorkItem?

    public init(_ explanation: String) {
        self.explanation = explanation
    }

    public var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isShowingPopover ? SpaceSenseTheme.accent : SpaceSenseTheme.slate)
            .padding(2)
            .contentShape(Rectangle())
            .onHover { hovering in
                dismissWorkItem?.cancel()
                if hovering {
                    isShowingPopover = true
                } else {
                    let work = DispatchWorkItem {
                        isShowingPopover = false
                    }
                    dismissWorkItem = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
                }
            }
            .onTapGesture {
                isShowingPopover.toggle()
            }
            .popover(isPresented: $isShowingPopover, arrowEdge: .bottom) {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .padding(10)
                    .frame(width: 250, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
    }
}

public struct SurfaceCard<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    public init(padding: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(SpaceSenseTheme.slate.opacity(0.18), lineWidth: 1)
            )
    }
}

public struct MetricCardView: View {
    public let title: String
    public let value: String
    public let subtitle: String
    public let icon: String
    public let tint: Color
    public let tooltip: String?

    public init(
        title: String,
        value: String,
        subtitle: String,
        icon: String,
        tint: Color,
        tooltip: String? = nil
    ) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
        self.tooltip = tooltip
    }

    public var body: some View {
        SurfaceCard(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 26, height: 26)
                        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    Spacer(minLength: 4)
                    if let tooltip {
                        InfoTooltipIcon(tooltip)
                    }
                }
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(SpaceSenseTheme.slate)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

public struct SectionHeaderBar: View {
    public let title: String
    public let subtitle: String
    public let icon: String

    public init(title: String, subtitle: String, icon: String) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(SpaceSenseTheme.accent)
                .frame(width: 34, height: 34)
                .background(
                    SpaceSenseTheme.accent.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(SpaceSenseTheme.slate)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 4)
        }
    }
}

public struct ScanProgressBanner: View {
    public let progress: ScanProgress
    public let onCancel: () -> Void

    public init(progress: ScanProgress, onCancel: @escaping () -> Void) {
        self.progress = progress
        self.onCancel = onCancel
    }

    public var body: some View {
        SurfaceCard(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning Filesystem…")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(Int(progress.percent))%")
                        .font(.subheadline.monospacedDigit().weight(.bold))
                        .foregroundStyle(SpaceSenseTheme.accent)
                    Text("• \(progress.filesScanned.formatted()) files (\(ByteFormatting.string(progress.bytesScanned)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(SpaceSenseTheme.slate)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 4)
                    Button(role: .cancel, action: onCancel) {
                        Label("Stop Scan", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                ProgressView(value: progress.percent, total: 100.0)
                    .progressViewStyle(.linear)
                    .tint(SpaceSenseTheme.accent)

                Text(progress.currentPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(SpaceSenseTheme.slate)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(progress.currentPath)
            }
        }
    }
}
