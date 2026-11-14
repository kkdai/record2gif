import AppKit
import Foundation

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let idleMenu: NSMenu
    var onNewRecording: (() -> Void)?
    var onStopRecording: (() -> Void)?

    override init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.idleMenu = NSMenu()
        super.init()
        self.statusItem.autosaveName = "com.kkdai.record2gif.statusItem"
        self.statusItem.isVisible = true
        setupMenu()
        showIdle()
    }

    private func setupMenu() {
        let newRecordingItem = NSMenuItem(
            title: "New Recording",
            action: #selector(handleNewRecording),
            keyEquivalent: "n"
        )
        newRecordingItem.target = self
        idleMenu.addItem(newRecordingItem)

        idleMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(handleQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        idleMenu.addItem(quitItem)
    }

    func showIdle() {
        statusItem.isVisible = true
        guard let button = statusItem.button else { return }
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = NSImage(
            systemSymbolName: "record.circle",
            accessibilityDescription: "record2gif"
        )?.withSymbolConfiguration(symbolConfig)
        image?.isTemplate = true
        button.image = image
        button.title = ""
        button.imagePosition = .imageOnly
        button.action = nil
        button.target = nil
        statusItem.menu = idleMenu
    }

    func showRecording(elapsed: TimeInterval) {
        statusItem.isVisible = true
        guard let button = statusItem.button else { return }
        let totalSeconds = max(0, Int(elapsed.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let timeString = String(format: "%02d:%02d", minutes, seconds)

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let image = NSImage(
            systemSymbolName: "stop.circle.fill",
            accessibilityDescription: "Stop Recording"
        )?.withSymbolConfiguration(symbolConfig)
        image?.isTemplate = true
        button.image = image
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        button.title = " \(timeString)"
        button.imagePosition = .imageLeading
        statusItem.menu = nil
        button.target = self
        button.action = #selector(handleStopRecording)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func handleNewRecording() {
        onNewRecording?()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func handleStopRecording() {
        onStopRecording?()
    }

    @objc private func handleQuit() {
        NSApp.terminate(nil)
    }
}
