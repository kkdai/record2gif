import Combine
import Foundation
import Record2GifCore

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case selectingArea
        case recording
        case exporting(URL)
    }

    @Published var phase: Phase = .idle
    let recorder = ScreenRecorder()
    weak var statusItemController: StatusItemController?
    var onStopRecordingRequested: (() -> Void)?
    var onNewRecordingRequested: (() -> Void)?
}
