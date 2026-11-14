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

    @Published var phase: Phase = .idle {
        didSet {
            syncStatusItem()
        }
    }
    let recorder = ScreenRecorder()
    weak var statusItemController: StatusItemController? {
        didSet {
            syncStatusItem()
        }
    }
    var onStopRecordingRequested: (() -> Void)?
    var onNewRecordingRequested: (() -> Void)?

    private var cancellables: Set<AnyCancellable> = []

    init() {
        recorder.$elapsed
            .sink { [weak self] elapsed in
                guard let self, self.phase == .recording else { return }
                self.statusItemController?.showRecording(elapsed: elapsed)
            }
            .store(in: &cancellables)
    }

    private func syncStatusItem() {
        guard let statusItemController else { return }
        if phase == .recording {
            statusItemController.showRecording(elapsed: recorder.elapsed)
        } else {
            statusItemController.showIdle()
        }
    }
}
