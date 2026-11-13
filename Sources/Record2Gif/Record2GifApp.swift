import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItemController: StatusItemController?
    weak var appModel: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let controller = StatusItemController()
        controller.onNewRecording = { [weak self] in
            self?.appModel?.phase = .idle
        }
        self.statusItemController = controller
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct Record2GifApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("record2gif") {
            contentView
                .environmentObject(model)
                .onAppear {
                    appDelegate.appModel = model
                }
        }
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
