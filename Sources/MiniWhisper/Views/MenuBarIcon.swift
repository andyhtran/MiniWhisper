import SwiftUI

/// Renders all menu bar icon states into NSImage so the view identity stays
/// stable across state transitions (no flicker). SF Symbols are rasterized
/// through NSImage(symbolName:) for idle/processing; the recording state
/// draws custom animated bars.
enum MenuBarIconRenderer {
    // Bar geometry for the recording meter
    private static let barWidth: CGFloat = 3
    private static let barSpacing: CGFloat = 2
    private static let maxHeight: CGFloat = 16
    private static let sideScale: CGFloat = 0.65
    private static let minFraction: CGFloat = 0.2

    static func render(state: RecordingState, meterLevel: Double) -> NSImage {
        switch state {
        case .recording:
            return renderMeterBars(level: meterLevel)
        case .processing:
            return renderSymbol("waveform.badge.ellipsis")
        default:
            return renderSymbol("waveform")
        }
    }

    /// Render an SF Symbol as a template NSImage sized for the menu bar.
    private static func renderSymbol(_ name: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            let configured = image.withSymbolConfiguration(config) ?? image
            configured.isTemplate = true
            return configured
        }
        // Fallback — should never happen with known symbol names
        return NSImage(size: NSSize(width: 18, height: 18))
    }

    /// Draw three rounded red bars whose height tracks the mic level.
    private static func renderMeterBars(level: Double) -> NSImage {
        let totalWidth = barWidth * 3 + barSpacing * 2
        let size = NSSize(width: totalWidth, height: maxHeight)

        let image = NSImage(size: size, flipped: false) { _ in
            let effectiveLevel = minFraction + CGFloat(level) * (1.0 - minFraction)

            let scales: [CGFloat] = [sideScale, 1.0, sideScale]
            for (i, scale) in scales.enumerated() {
                let barHeight = max(maxHeight * effectiveLevel * scale, barWidth)
                let x = CGFloat(i) * (barWidth + barSpacing)
                let y = (maxHeight - barHeight) / 2.0
                let barRect = NSRect(x: x, y: y, width: barWidth, height: barHeight)
                let path = NSBezierPath(
                    roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)
                NSColor.systemRed.setFill()
                path.fill()
            }
            return true
        }

        image.isTemplate = false
        return image
    }
}
