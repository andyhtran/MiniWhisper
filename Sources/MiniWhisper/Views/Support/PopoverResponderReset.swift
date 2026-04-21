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
