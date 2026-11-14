import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItemController: StatusItemController? {
        didSet {
            appModel?.statusItemController = statusItemController
        }
    }
    weak var appModel: AppModel? {
        didSet {
            if let statusItemController {
                appModel?.statusItemController = statusItemController
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let controller = StatusItemController()
        controller.onNewRecording = { [weak self] in
            guard let self else { return }
            if self.appModel?.phase != .recording {
                self.appModel?.phase = .idle
                self.appModel?.onNewRecordingRequested?()
                self.bringMainWindowToFront()
            }
        }
        controller.onStopRecording = { [weak self] in
            self?.appModel?.onStopRecordingRequested?()
        }
        self.statusItemController = controller
        self.appModel?.statusItemController = controller
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func bringMainWindowToFront() {
        let targetWindow = NSApp.windows.first(where: { window in
            window.identifier?.rawValue == "main" || window.title == "record2gif"
        }) ?? NSApp.windows.first(where: { window in
            !(window is NSPanel) && window.className != "NSStatusBarWindow"
        })
        targetWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct Record2GifApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("record2gif", id: "main") {
            contentView
                .environmentObject(model)
                .onAppear {
                    appDelegate.appModel = model
                    if let controller = appDelegate.statusItemController {
                        model.statusItemController = controller
                    }
                }
        }
        .windowResizability(.contentSize)
    }

    @ViewBuilder
    private var contentView: some View {
        switch model.phase {
        case .idle, .selectingArea, .recording:
            RecordingControlView()
        case .exporting(let videoURL):
            ExportView(videoURL: videoURL)
        }
    }
}
