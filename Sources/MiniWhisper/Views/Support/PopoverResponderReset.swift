import SwiftUI

// MARK: - Popover Responder Cleanup

// SwiftUI's `.popover` tears down its hosting window while a TextField inside
// can still be first responder. The orphaned NSTextView then lives on,
// registered as responder for a now-null window, and the next popover that
// tries to set up first responder crashes in -[NSWindow _newFirstResponderAfterResigning].
//
// PopoverResponderResetView sits invisibly in the popover content and watches
// for `viewWillMove(toWindow: nil)` — the last point where the popover's
// window is still live. At that moment we tell the window to clear its first
// responder cleanly, which gives the TextField a chance to resignFirstResponder
// while its window still exists.
struct PopoverResponderReset: NSViewRepresentable {
    final class ResetView: NSView {
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, let current = self.window {
                current.makeFirstResponder(nil)
            }
            super.viewWillMove(toWindow: newWindow)
        }
    }

    func makeNSView(context: Context) -> NSView { ResetView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    func resignsResponderOnClose() -> some View {
        background(PopoverResponderReset().frame(width: 0, height: 0).allowsHitTesting(false))
    }
}

// MARK: - Popover Focus Sink

// SwiftUI's `.popover` auto-focuses the first NSTextField in its window,
// which makes NSTextField's field editor select all the text. Clearing
// first responder after the fact loses a race against SwiftUI's focus pass.
//
// Instead we plant an invisible NSView that accepts first responder and
// becomes the window's `initialFirstResponder`. AppKit then focuses the
// sink on open and the TextFields stay untouched until the user clicks
// into one. Trade-offs accepted:
//   - Sink is out of the Tab loop (canBecomeKeyView = false), so Tab
//     still moves between the real fields, not through the sink.
//   - Sink is accessibility-hidden so VoiceOver doesn't announce it.
//   - Keystrokes before the user clicks into a field go to the sink and
//     are dropped — which is the desired behavior (no accidental edits).
struct PopoverFocusSink: NSViewRepresentable {
    final class SinkView: NSView {
        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { false }
        override func drawFocusRingMask() {}
        override var focusRingMaskBounds: NSRect { .zero }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.initialFirstResponder = self
            if window.isKeyWindow {
                window.makeFirstResponder(self)
            }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = SinkView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    func popoverFocusSink() -> some View {
        background(PopoverFocusSink().frame(width: 0, height: 0).allowsHitTesting(false))
    }
}
