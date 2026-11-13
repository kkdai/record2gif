import Combine
import CoreGraphics
import Foundation

@MainActor
public final class ScreenRecorder: ObservableObject {
    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var elapsed: TimeInterval = 0

    public init() {}

    public static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    public static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public func availableDisplays() async throws -> [DisplayInfo] {
        fatalError("not implemented")
    }

    public func start(_ options: RecordingOptions) async throws {
        fatalError("not implemented")
    }

    public func stop() async throws -> URL {
        fatalError("not implemented")
    }
}

public enum RecorderError: Error, Equatable, Sendable {
    case permissionDenied
    case displayNotFound
    case alreadyRecording
    case notRecording
    case writerFailed(String)
}
