import SwiftUI
import AppKit

/// Tiny `info.circle` icon that shows a tooltip popover the instant the
/// cursor enters it. Replaces SwiftUI's `.help()` modifier where the
/// ~2-second NSToolTip delay feels sluggish for short hint text.
///
/// Drop next to a label inside an `HStack(spacing: 4)`:
///
///     HStack(spacing: 4) {
///         Text("Trailing space")
///         InfoBadge(text: "Append a space after each pasted transcription …")
///         Spacer()
///         Toggle(…)
///     }
///
/// Built on AppKit's `NSTrackingArea` + `NSPopover` rather than SwiftUI's
/// `.onHover` + `.popover(isPresented:)`. Inside a `Form` row on macOS, that
/// SwiftUI pair fights the Form's own row layout passes: the anchor's frame
/// gets recomputed while the popover is open, which both retriggers
/// `onHover` (show/hide/show looping — the "pulsing") and feeds the popover
/// a stale intrinsic size before the Form settles (the "way too tall" first
/// frame). AppKit's tracking area and `NSPopover` sit outside that render
/// loop entirely, and the content size below is computed once, explicitly,
/// from the already-laid-out hosting view — so neither failure mode has
/// anywhere to come from.
struct InfoBadge: View {
    let text: String

    var body: some View {
        InfoBadgeHoverRepresentable(text: text)
            .frame(width: 14, height: 14)
    }
}

private struct InfoBadgeHoverRepresentable: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> InfoBadgeHoverView {
        InfoBadgeHoverView(text: text)
    }

    func updateNSView(_ nsView: InfoBadgeHoverView, context: Context) {
        nsView.text = text
    }
}

final class InfoBadgeHoverView: NSView {
    var text: String {
        didSet { if text != oldValue { closePopover() } }
    }

    private let imageView: NSImageView
    private let popover = NSPopover()
    private var trackingArea: NSTrackingArea?
    private var pollTimer: Timer?

    init(text: String) {
        self.text = text
        imageView = NSImageView()
        super.init(frame: .zero)

        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        imageView.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: text)?
            .withSymbolConfiguration(config)
        imageView.contentTintColor = .secondaryLabelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        popover.behavior = .applicationDefined
        popover.animates = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // macOS (Sonoma onward) has a standing AppKit regression where a
    // tracking area's mouseEntered/mouseExited can fire spuriously — wrong
    // locationInWindow, or a pair neither of which reflects where the
    // pointer actually is — once another window (here, the popover itself)
    // appears above the view. Apple Feedback FB13698735 and FB11988707
    // describe the same family of bug. Trusting these events for the *close*
    // decision is exactly what produced the flicker: open, spurious exit,
    // close, pointer is still there so immediately re-enter, open again.
    //
    // So the events keep their old job of *opening* (cheap, and a spurious
    // enter is harmless — it just shows what's already about to be true),
    // but closing is decided by independently asking the system where the
    // pointer really is, polled for as long as the popover is open. That
    // sidesteps the bug entirely rather than trying to filter it.
    override func mouseEntered(with event: NSEvent) {
        showPopover()
    }

    override func mouseExited(with event: NSEvent) {
        checkPointerAndCloseIfOutside()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { closePopover() }
    }

    private func showPopover() {
        if popover.isShown {
            startPolling()  // covers a spurious re-enter arriving without a preceding real exit
            return
        }

        // `maxWidth: 220` (a ceiling) needs something to measure against to
        // resolve to an actual width — and this hosting view isn't in a
        // window yet when `fittingSize` runs below, so there's no ambient
        // proposed size to give it. SwiftUI falls back to an ~unconstrained
        // width, `fixedSize(vertical: true)` then wraps that "line" of text
        // into a column about one word wide, and the resulting fittingSize
        // is a handful of points wide and hundreds tall — the huge popover.
        // `frame(width: 220)` (exact, not max) removes the ambiguity: the
        // view now states its own width outright, so `fittingSize` has
        // nothing left to guess.
        let content = Text(text)
            .font(.system(size: 12))
            .foregroundColor(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: 220, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

        let hosting = NSHostingController(rootView: content)
        // Computed once, up front, from a view that has actually been laid
        // out — not left for the popover to guess at while its own anchor is
        // still moving. `fittingSize` after a forced layout pass is stable;
        // NSPopover's own auto-sizing (like SwiftUI's `.popover`) is what
        // produced the oversized first frame.
        hosting.view.layoutSubtreeIfNeeded()
        let fitting = hosting.view.fittingSize
        // Defense in depth: even a correctly-measured tooltip should never
        // need to be taller than this, so a future regression of the same
        // kind degrades to a scrollable-looking popover instead of one that
        // runs off the bottom of the screen again.
        popover.contentSize = NSSize(width: fitting.width, height: min(fitting.height, 400))
        popover.contentViewController = hosting

        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        startPolling()
    }

    private func closePopover() {
        stopPolling()
        guard popover.isShown else { return }
        popover.close()
    }

    /// Ground truth for "is the pointer actually over this icon", read
    /// straight from the system rather than from a tracking event. Screen
    /// coordinates in, converted through this view's own window and
    /// coordinate space — independent of whatever the popover's window is
    /// doing.
    private func isPointerInsideBounds() -> Bool {
        guard let window else { return false }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let viewPoint = convert(windowPoint, from: nil)
        return bounds.insetBy(dx: -2, dy: -2).contains(viewPoint)
    }

    private func checkPointerAndCloseIfOutside() {
        guard popover.isShown else { return }
        if !isPointerInsideBounds() {
            closePopover()
        }
    }

    /// Safety net while the popover is open: if the pointer genuinely
    /// leaves but the buggy tracking area never delivers a usable exit
    /// (the other half of the same regression), this is what still closes
    /// it instead of leaving it stuck open.
    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPointerAndCloseIfOutside() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

struct InfoLabel: View {
    let title: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            InfoBadge(text: text)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}
