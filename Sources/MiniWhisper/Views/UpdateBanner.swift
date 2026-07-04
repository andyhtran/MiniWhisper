import SwiftUI

/// Inline banner in the menu popover that renders the whole update pipeline
/// — available → downloading → preparing → installing — plus check results
/// and errors. This is the app's only update UI; Sparkle's own windows are
/// suppressed by the custom user driver.
struct UpdateBanner: View {
    @Environment(\.updaterController) private var updaterController
    let model: UpdateViewModel

    var body: some View {
        switch model.state {
        case .idle:
            EmptyView()

        case .checking(let checking):
            BannerRow(tint: .blue, onClose: checking.cancel) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 20)
            } content: {
                BannerTitle("Checking for Updates…")
            }

        case .updateAvailable(let update):
            AvailableBannerRow(update: update)

        case .downloading(let download):
            BannerRow(tint: .blue, onClose: download.cancel) {
                BannerIcon("arrow.down.circle.fill", color: .blue)
            } content: {
                BannerProgress(
                    title: "Downloading Update…",
                    fraction: download.fraction)
            }

        case .extracting(let extracting):
            BannerRow(tint: .blue, onClose: nil) {
                BannerIcon("shippingbox.fill", color: .blue)
            } content: {
                BannerProgress(
                    title: "Preparing Update…",
                    fraction: extracting.progress)
            }

        case .installing:
            BannerRow(tint: .blue, onClose: nil) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 20)
            } content: {
                BannerTitle(
                    "Installing Update…",
                    subtitle: "MiniWhisper will relaunch")
            }

        case .notFound(let notFound):
            BannerRow(tint: .green, onClose: notFound.acknowledge) {
                BannerIcon("checkmark.circle.fill", color: .green)
            } content: {
                BannerTitle(
                    "You're up to date",
                    subtitle: "MiniWhisper \(AppVersionInfo.current.displayString)")
            }

        case .failed(let failure):
            BannerRow(tint: .orange, onClose: failure.dismiss) {
                BannerIcon("exclamationmark.triangle.fill", color: .orange)
            } content: {
                HStack(spacing: 8) {
                    BannerTitle("Update Failed", subtitle: failure.message)
                    Spacer(minLength: 0)
                    Button("Retry") {
                        updaterController?.checkForUpdates(nil)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.orange)
                }
            }
        }
    }
}

/// The "Update Available" state keeps the old banner's affordance: the whole
/// row is the install action, with a separate close button for "later".
private struct AvailableBannerRow: View {
    let update: UpdateState.Available
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: update.install) {
                HStack(spacing: 8) {
                    BannerIcon("arrow.down.circle.fill", color: .blue)
                    BannerTitle("Update Available", subtitle: subtitle)
                    Spacer(minLength: 0)
                    Text("Install")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.blue)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            BannerCloseButton(action: update.dismiss)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovering ? Color.blue.opacity(0.08) : Color.blue.opacity(0.04))
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }

    private var subtitle: String {
        var text = "MiniWhisper \(update.version)"
        if let byteCount = update.byteCount {
            let size = ByteCountFormatter.string(
                fromByteCount: byteCount, countStyle: .file)
            text += " · \(size)"
        }
        return text
    }
}

// MARK: - Building blocks

private struct BannerRow<Leading: View, Content: View>: View {
    let tint: Color
    let onClose: (() -> Void)?
    @ViewBuilder let leading: Leading
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) {
            leading
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onClose {
                BannerCloseButton(action: onClose)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(tint.opacity(0.05))
        )
    }
}

private struct BannerIcon: View {
    let name: String
    let color: Color

    init(_ name: String, color: Color) {
        self.name = name
        self.color = color
    }

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 12))
            .foregroundColor(color)
            .frame(width: 20)
    }
}

private struct BannerTitle: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

private struct BannerProgress: View {
    let title: String
    /// Nil renders an indeterminate bar.
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                if let fraction {
                    Text("\(Int(fraction * 100))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .controlSize(.small)
        }
    }
}

private struct BannerCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
