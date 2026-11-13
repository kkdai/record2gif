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
        guard let button = statusItem.button else { return }
        let image = NSImage(
            systemSymbolName: "record.circle",
            accessibilityDescription: "record2gif"
        )
        image?.isTemplate = true
        button.image = image
        button.title = ""
        button.imagePosition = .imageOnly
        button.action = nil
        button.target = nil
        statusItem.menu = idleMenu
    }

    func showRecording(elapsed: TimeInterval) {
        guard let button = statusItem.button else { return }
        let totalSeconds = max(0, Int(elapsed.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let timeString = String(format: "%02d:%02d", minutes, seconds)

        let image = NSImage(
            systemSymbolName: "stop.circle.fill",
            accessibilityDescription: "Stop Recording"
        )
        image?.isTemplate = true
        button.image = image
        button.title = " \(timeString)"
        button.imagePosition = .imageLeading
        if onStopRecording != nil {
            statusItem.menu = nil
            button.target = self
            button.action = #selector(handleStopRecording)
        } else {
            statusItem.menu = idleMenu
        }
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
