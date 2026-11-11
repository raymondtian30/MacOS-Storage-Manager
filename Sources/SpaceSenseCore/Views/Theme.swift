import SwiftUI

public enum SpaceSenseTheme {
    public static let accent = Color(red: 0.32, green: 0.58, blue: 0.98)
    public static let secondaryAccent = Color(red: 0.42, green: 0.78, blue: 0.66)
    public static let warning = Color(red: 0.96, green: 0.65, blue: 0.23)
    public static let danger = Color(red: 0.94, green: 0.36, blue: 0.40)
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
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
            )
    }
}

public struct MetricCardView: View {
    public let title: String
    public let value: String
    public let subtitle: String
    public let icon: String
    public let tint: Color

    public init(title: String, value: String, subtitle: String, icon: String, tint: Color) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
    }

    public var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 28, height: 28)
                        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    Spacer()
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
                    .foregroundStyle(.secondary)
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
                .frame(width: 36, height: 36)
                .background(
                    SpaceSenseTheme.accent.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.bold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
        SurfaceCard(padding: 12) {
            HStack(spacing: 14) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 10) {
                        Text("Scanning Filesystem...")
                            .font(.subheadline.weight(.semibold))
                        Text("\(progress.filesScanned.formatted()) files • \(ByteFormatting.string(progress.bytesScanned))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(progress.currentPath)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(role: .cancel, action: onCancel) {
                    Label("Cancel Scan", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}
