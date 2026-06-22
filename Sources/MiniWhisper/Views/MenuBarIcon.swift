import SwiftUI

/// Renders all menu bar icon states into NSImage so the view identity stays
/// stable across state transitions (no flicker). Idle rasterizes an SF
/// Symbol; recording draws red level-tracking bars; the working states
/// (transcription, edit-mode AI call) draw pulsing bars whose phase must be
/// advanced by an external timer — nothing observable ticks while they run.
enum MenuBarIconRenderer {
    // Bar geometry for the recording meter
    private static let barWidth: CGFloat = 3
    private static let barSpacing: CGFloat = 2
    private static let maxHeight: CGFloat = 16
    private static let sideScale: CGFloat = 0.65
    private static let minFraction: CGFloat = 0.2

    static func render(
        state: RecordingState, meterLevel: Double, isEditModeProcessing: Bool = false,
        processingPhase: Double = 0
    ) -> NSImage {
        // Edit-mode AI call wins over the generic processing icon — the
        // user pressed a different shortcut for a different operation, so
        // the menu bar should reflect that's what's running (distinct tint).
        if isEditModeProcessing {
            return renderPulsingBars(phase: processingPhase, color: .systemPurple)
        }
        switch state {
        case .recording:
            return renderMeterBars(level: meterLevel)
        case .processing:
            return renderPulsingBars(phase: processingPhase, color: .systemOrange)
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
        let effectiveLevel = minFraction + CGFloat(level) * (1.0 - minFraction)
        let scales: [CGFloat] = [sideScale, 1.0, sideScale]
        return drawBars(heightFractions: scales.map { effectiveLevel * $0 }, color: .systemRed)
    }

    /// Calm pulsing bars for the "working" states (transcription, edit-mode
    /// AI call). Same geometry as the recording meter but a non-red tint and
    /// a self-driven wave, so "working" reads differently from "listening"
    /// while still clearly not idle.
    private static func renderPulsingBars(phase: Double, color: NSColor) -> NSImage {
        drawBars(heightFractions: pulsingBarFractions(phase: phase), color: color)
    }

    /// Gentle travelling wave around mid-height; per-bar offset makes the
    /// motion read left-to-right. `phase` is one full cycle over [0, 1).
    static func pulsingBarFractions(phase: Double) -> [CGFloat] {
        (0..<3).map { i in
            let angle = 2 * Double.pi * phase - Double(i) * 0.9
            return 0.45 + 0.2 * CGFloat(sin(angle))
        }
    }

    private static func drawBars(heightFractions: [CGFloat], color: NSColor) -> NSImage {
        let totalWidth =
            barWidth * CGFloat(heightFractions.count)
            + barSpacing * CGFloat(heightFractions.count - 1)
        let size = NSSize(width: totalWidth, height: maxHeight)

        let image = NSImage(size: size, flipped: false) { _ in
            for (i, fraction) in heightFractions.enumerated() {
                let barHeight = max(maxHeight * fraction, barWidth)
                let x = CGFloat(i) * (barWidth + barSpacing)
                let y = (maxHeight - barHeight) / 2.0
                let barRect = NSRect(x: x, y: y, width: barWidth, height: barHeight)
                let path = NSBezierPath(
                    roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)
                color.setFill()
                path.fill()
            }
            return true
        }

        image.isTemplate = false
        return image
    }
}
