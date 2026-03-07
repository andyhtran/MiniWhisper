import Foundation
import AppKit
import Carbon.HIToolbox
import os.log

final class PasteboardService: @unchecked Sendable {
    private let logger = Logger(subsystem: Logger.subsystem, category: "PasteboardService")
    // MARK: - Types

    private struct SavedPasteboardContents {
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

        let pasteboard = NSPasteboard.general

        let savedContents = saveCurrentPasteboardContents()

        let changeCountBefore = pasteboard.changeCount

        guard copy(text) else {
            logger.error("Failed to copy text to clipboard")
            return
        }

        let changeCountAfter = pasteboard.changeCount

        if changeCountAfter > changeCountBefore {
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
        } else {
            logger.error("Copy did not change clipboard")
        }
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
