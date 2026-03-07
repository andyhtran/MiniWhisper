import AppKit
import SwiftUI

@MainActor
final class ToastWindowController: Sendable {
    static let shared = ToastWindowController()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var currentToast: ToastMessage?
    private var dismissTask: Task<Void, Never>?

    private let panelWidth: CGFloat = 350
    private let panelHeight: CGFloat = 80

    func show(_ toast: ToastMessage) {
        dismissTask?.cancel()

        currentToast = toast
        if panel != nil {
            updateHostingView(toast: toast)
        } else {
            createAndShowPanel(toast: toast)
        }
    }

    func showError(title: String, message: String? = nil) {
        show(ToastMessage(type: .error, title: title, message: message))
    }

    func dismiss() {
        dismissTask?.cancel()

        guard panel != nil else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.panel?.orderOut(nil)
                self?.panel = nil
                self?.hostingView = nil
                self?.currentToast = nil
            }
        })
    }

    private func createAndShowPanel(toast: ToastMessage) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false

        let hostingView = NSHostingView(rootView: AnyView(
            ToastView(toast: toast) { [weak self] in
                self?.dismiss()
            }
            .frame(width: panelWidth)
        ))

        panel.contentView = hostingView

        positionPanel(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        self.panel = panel
        self.hostingView = hostingView
    }

    private func updateHostingView(toast: ToastMessage) {
        hostingView?.rootView = AnyView(
            ToastView(toast: toast) { [weak self] in
                self?.dismiss()
            }
            .frame(width: panelWidth)
        )
    }

    private func positionPanel(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]

        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - panelWidth / 2
        let y = visibleFrame.maxY - panelHeight - 8

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
