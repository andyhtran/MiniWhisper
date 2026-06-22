import Foundation
import AppKit
import Carbon.HIToolbox
import os.log

final class PasteboardService: @unchecked Sendable {
    private let logger = Logger(subsystem: Logger.subsystem, category: "PasteboardService")
    // MARK: - Types

    struct SavedPasteboardContents: Sendable {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    // MARK: - Clipboard Operations

    @discardableResult
    func copy(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    func copyAndPaste(_ text: String) {
        logger.info("copyAndPaste called with \(text.count) characters")

        let savedContents = saveCurrentPasteboardContents()

        guard copy(text) else {
            logger.error("Failed to copy text to clipboard")
            return
        }

        logger.info("Copy succeeded, simulating paste...")

        // 50ms: let the frontmost app's run loop process the clipboard change before pasting
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.simulatePaste()

            // 300ms: wait for the target app to read the pasted content before restoring
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.restorePasteboardContents(savedContents)
                self?.logger.info("Clipboard restored")
            }
        }
    }

    // MARK: - Selection Capture (Edit Mode)

    /// Saves the current pasteboard, synthesizes ⌘C to capture the
    /// frontmost app's selection, polls until the change-count actually
    /// advances (or times out), then returns the captured string and the
    /// saved pasteboard so the caller can restore later.
    ///
    /// Returns `nil` if no text was selected (change-count never advanced
    /// or the resulting string was empty). The original pasteboard is
    /// restored automatically in the no-selection case so the user
    /// doesn't lose what they had.
    func captureSelection() async -> (text: String, saved: SavedPasteboardContents?)? {
        let pasteboard = NSPasteboard.general
        let saved = saveCurrentPasteboardContents()
        let initialChangeCount = pasteboard.changeCount

        simulateCopy()

        // Poll for clipboard change. ⌘C is asynchronous — the frontmost
        // app's run loop has to process the keystroke and write to the
        // pasteboard. 300ms is generous for any responsive app.
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            if pasteboard.changeCount > initialChangeCount { break }
            try? await Task.sleep(nanoseconds: 15_000_000)  // 15ms
        }

        guard pasteboard.changeCount > initialChangeCount else {
            restorePasteboardContents(saved)
            return nil
        }

        let captured = pasteboard.string(forType: .string) ?? ""
        guard !captured.isEmpty else {
            restorePasteboardContents(saved)
            return nil
        }

        return (captured, saved)
    }

    /// Companion to `captureSelection`: writes `text` to the pasteboard,
    /// synthesizes ⌘V, then restores the previously-saved pasteboard
    /// contents after a short delay so the target app finishes reading.
    func pasteAndRestore(_ text: String, savedPasteboard: SavedPasteboardContents?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.simulatePaste()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.restorePasteboardContents(savedPasteboard)
            }
        }
    }

    /// Restore the saved pasteboard immediately — used on edit-flow errors
    /// where we never paste anything and want the user's clipboard back.
    func restoreSavedPasteboard(_ savedPasteboard: SavedPasteboardContents?) {
        restorePasteboardContents(savedPasteboard)
    }

    private func simulateCopy() {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(
            keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        else {
            logger.error("Failed to create copy keyDown event")
            return
        }
        keyDown.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)

        usleep(10000)

        guard let keyUp = CGEvent(
            keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        else {
            logger.error("Failed to create copy keyUp event")
            return
        }
        keyUp.flags = .maskCommand
        keyUp.post(tap: .cghidEventTap)
    }

    // MARK: - Clipboard Save/Restore

    private func saveCurrentPasteboardContents() -> SavedPasteboardContents? {
        let pasteboard = NSPasteboard.general

        guard let items = pasteboard.pasteboardItems else {
            return nil
        }

        var savedItems: [[NSPasteboard.PasteboardType: Data]] = []

        for item in items {
            var itemData: [NSPasteboard.PasteboardType: Data] = [:]

            for type in item.types {
                if let data = item.data(forType: type) {
                    itemData[type] = data
                }
            }

            if !itemData.isEmpty {
                savedItems.append(itemData)
            }
        }

        return savedItems.isEmpty ? nil : SavedPasteboardContents(items: savedItems)
    }

    private func restorePasteboardContents(_ saved: SavedPasteboardContents?) {
        guard let saved = saved, !saved.items.isEmpty else {
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        for itemData in saved.items {
            let item = NSPasteboardItem()

            for (type, data) in itemData {
                item.setData(data, forType: type)
            }

            pasteboard.writeObjects([item])
        }
    }

    // MARK: - Keystroke Simulation

    private func simulatePaste() {
        logger.info("Simulating Cmd+V paste...")

        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true) else {
            logger.error("Failed to create keyDown event - check Accessibility permissions")
            return
        }
        keyDown.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)

        // 10ms gap so the target app sees distinct keyDown/keyUp events
        usleep(10000)

        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            logger.error("Failed to create keyUp event")
            return
        }
        keyUp.flags = .maskCommand
        keyUp.post(tap: .cghidEventTap)

        logger.info("Paste keystroke sent")
    }

}
