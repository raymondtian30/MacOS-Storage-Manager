import SwiftUI

/// Sleek 3-color palette:
/// 1. Electric Cyan (`accent`)
/// 2. Emerald Mint (`secondaryAccent`)
/// 3. Cool Slate (`slate`)
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
    @State private var isHovering: Bool = false

    public init(_ explanation: String) {
        self.explanation = explanation
    }

    public var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isHovering ? SpaceSenseTheme.accent : SpaceSenseTheme.slate)
            .onHover { hovering in
                isHovering = hovering
            }
            .popover(isPresented: $isHovering, arrowEdge: .top) {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .padding(10)
                    .frame(width: 260, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .help(explanation)
    }
}

public struct SurfaceCard<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    public init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
            )
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
        SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 28, height: 28)
                        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Spacer()
                    if let tooltip {
                        InfoTooltipIcon(tooltip)
                    }
                }
                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(SpaceSenseTheme.slate)
                    .lineLimit(1)
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
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(SpaceSenseTheme.accent)
                .frame(width: 38, height: 38)
                .background(
                    SpaceSenseTheme.accent.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.bold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(SpaceSenseTheme.slate)
            }
            Spacer()
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
        SurfaceCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning Filesystem…")
                        .font(.subheadline.weight(.semibold))
                    Text("\(Int(progress.percent))%")
                        .font(.subheadline.monospacedDigit().weight(.bold))
                        .foregroundStyle(SpaceSenseTheme.accent)
                    Text("• \(progress.filesScanned.formatted()) files (\(ByteFormatting.string(progress.bytesScanned)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(SpaceSenseTheme.slate)
                    Spacer()
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
            }
        }
    }
}
