import AppKit
import AVFoundation
import Combine
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

@MainActor
public final class ScreenRecorder: ObservableObject {
    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var elapsed: TimeInterval = 0

    private var activeSession: ActiveRecordingSession?
    private var elapsedTask: Task<Void, Never>?

    public init() {}

    public static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    public static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public func availableDisplays() async throws -> [DisplayInfo] {
        guard Self.hasPermission() else {
            throw RecorderError.permissionDenied
        }

        let content = try await fetchShareableContent()
        let screensByID = Self.nsScreensByDisplayID()
        let primaryHeight = NSScreen.screens.first?.frame.height
            ?? CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))

        return content.displays.map { scDisplay in
            if let screen = screensByID[scDisplay.displayID] {
                return DisplayInfo(
                    id: scDisplay.displayID,
                    name: screen.localizedName,
                    frame: screen.frame,
                    scale: screen.backingScaleFactor
                )
            } else {
                // Convert ScreenCaptureKit / CoreGraphics global coordinates (top-left origin
                // relative to the primary display) into AppKit global coordinates (bottom-left origin).
                let appKitFrame = CaptureGeometry.appKitFrame(
                    fromCGFrame: scDisplay.frame,
                    primaryScreenHeight: primaryHeight
                )
                return DisplayInfo(
                    id: scDisplay.displayID,
                    name: "Display \(scDisplay.displayID)",
                    frame: appKitFrame,
                    scale: 1.0
                )
            }
        }
    }

    public func start(_ options: RecordingOptions) async throws {
        guard !isRecording else {
            throw RecorderError.alreadyRecording
        }
        guard Self.hasPermission() else {
            throw RecorderError.permissionDenied
        }

        let content = try await fetchShareableContent()
        let targetDisplayID = CaptureGeometry.displayID(for: options.target)

        guard let scDisplay = content.displays.first(where: { $0.displayID == targetDisplayID }) else {
            throw RecorderError.displayNotFound
        }

        let screensByID = Self.nsScreensByDisplayID()
        let scale = screensByID[targetDisplayID]?.backingScaleFactor ?? 1.0
        let displayPointSize = CGSize(width: scDisplay.width, height: scDisplay.height)
        let dimensions = CaptureGeometry.pixelDimensions(
            for: options.target,
            displayPointSize: displayPointSize,
            scale: scale
        )

        let excludedIDs = Set(options.excludedWindowIDs)
        let excludedWindows = content.windows.filter { excludedIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: scDisplay, excludingWindows: excludedWindows)

        let configuration = SCStreamConfiguration()
        configuration.width = dimensions.width
        configuration.height = dimensions.height
        if let sourceRect = dimensions.sourceRect {
            configuration.sourceRect = sourceRect
        }
        configuration.minimumFrameInterval = CaptureGeometry.frameInterval(fps: options.fps)
        configuration.showsCursor = options.showsCursor
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 6

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("record2gif-\(UUID().uuidString).mov")

        let sampleQueue = DispatchQueue(
            label: "com.kkdai.record2gif.sampleQueue",
            qos: .userInitiated
        )
        let outputHandler = try StreamOutputHandler(
            outputURL: outputURL,
            width: dimensions.width,
            height: dimensions.height,
            sampleQueue: sampleQueue
        )

        let stream = SCStream(filter: filter, configuration: configuration, delegate: outputHandler)
        do {
            try stream.addStreamOutput(outputHandler, type: .screen, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
        } catch {
            sampleQueue.async {
                outputHandler.cancelAndCleanUp()
            }
            if !Self.hasPermission() {
                throw RecorderError.permissionDenied
            }
            throw RecorderError.writerFailed(error.localizedDescription)
        }

        let startDate = Date()
        activeSession = ActiveRecordingSession(
            stream: stream,
            outputHandler: outputHandler,
            sampleQueue: sampleQueue,
            outputURL: outputURL,
            startDate: startDate
        )
        elapsed = 0
        isRecording = true

        elapsedTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self, self.isRecording else { break }
                self.elapsed = Date().timeIntervalSince(startDate)
            }
        }
    }

    /// Stops the active screen recording, finalizes the `.mov` file in the temporary directory,
    /// and returns its URL.
    ///
    /// - Note: If no complete video frames arrived before `stop()` was called (for example,
    ///   an immediate stop or completely static stream with zero delivered buffers), this method
    ///   throws `RecorderError.writerFailed("no frames")` and removes the temporary file.
    public func stop() async throws -> URL {
        guard isRecording, let session = activeSession else {
            throw RecorderError.notRecording
        }

        // Capture host clock time immediately upon stop() so the final static frame extends
        // up to the moment recording was stopped (matching ScreenCaptureKit's PTS clock).
        let stopTime = CMClockGetTime(CMClockGetHostTimeClock())

        isRecording = false
        elapsedTask?.cancel()
        elapsedTask = nil
        elapsed = Date().timeIntervalSince(session.startDate)
        activeSession = nil

        try? await session.stream.stopCapture()

        return try await withCheckedThrowingContinuation { continuation in
            session.sampleQueue.async {
                session.outputHandler.finish(stopTime: stopTime, continuation: continuation)
            }
        }
    }

    // MARK: - Private Helpers

    private func fetchShareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            if !Self.hasPermission() {
                throw RecorderError.permissionDenied
            }
            throw RecorderError.writerFailed(error.localizedDescription)
        }
    }

    private static func nsScreensByDisplayID() -> [CGDirectDisplayID: NSScreen] {
        Dictionary(
            NSScreen.screens.compactMap { screen in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                    return nil
                }
                return (CGDirectDisplayID(number.uint32Value), screen)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

public enum RecorderError: Error, Equatable, Sendable {
    case permissionDenied
    case displayNotFound
    case alreadyRecording
    case notRecording
    case writerFailed(String)
}

// MARK: - Pure Capture Geometry Helpers

enum CaptureGeometry {
    struct PixelDimensions: Equatable, Sendable {
        let width: Int
        let height: Int
        let sourceRect: CGRect?
    }

    static func displayID(for target: CaptureTarget) -> CGDirectDisplayID {
        switch target {
        case .display(let id):
            return id
        case .area(let display, _):
            return display
        }
    }

    /// Rounds a floating-point pixel length to the nearest even integer (rounding half to even
    /// after rounding, then flooring odd values down by 1), clamped to a minimum of 2.
    static func roundToEven(_ value: CGFloat) -> Int {
        guard value.isFinite else { return 2 }
        let rounded = Int(value.rounded())
        let even = rounded & ~1
        return max(2, even)
    }

    /// Computes even pixel width/height and optional display-local `sourceRect` for `SCStreamConfiguration`.
    static func pixelDimensions(
        for target: CaptureTarget,
        displayPointSize: CGSize,
        scale: CGFloat
    ) -> PixelDimensions {
        let effectiveScale = (scale.isFinite && scale > 0) ? scale : 1.0
        switch target {
        case .display:
            let width = roundToEven(displayPointSize.width * effectiveScale)
            let height = roundToEven(displayPointSize.height * effectiveScale)
            return PixelDimensions(width: width, height: height, sourceRect: nil)
        case .area(_, let rect):
            let width = roundToEven(rect.width * effectiveScale)
            let height = roundToEven(rect.height * effectiveScale)
            return PixelDimensions(width: width, height: height, sourceRect: rect)
        }
    }

    static func frameInterval(fps: Int) -> CMTime {
        let clampedFPS = max(1, fps)
        return CMTime(value: 1, timescale: CMTimeScale(clampedFPS))
    }

    /// Converts a CoreGraphics global display rect (top-left origin of primary screen) into
    /// AppKit global coordinates (bottom-left origin of primary screen).
    static func appKitFrame(fromCGFrame cgFrame: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: cgFrame.origin.x,
            y: primaryScreenHeight - cgFrame.maxY,
            width: cgFrame.width,
            height: cgFrame.height
        )
    }

    /// Computes the writer session end timestamp as `max(stopTime, lastPTS)`.
    static func sessionEndTime(stopTime: CMTime, lastPTS: CMTime) -> CMTime {
        guard stopTime.isValid && !stopTime.isIndefinite else {
            return lastPTS
        }
        guard lastPTS.isValid && !lastPTS.isIndefinite else {
            return stopTime
        }
        return CMTimeMaximum(stopTime, lastPTS)
    }
}

// MARK: - Stream Output & Asset Writer Session

private struct ActiveRecordingSession {
    let stream: SCStream
    let outputHandler: StreamOutputHandler
    let sampleQueue: DispatchQueue
    let outputURL: URL
    let startDate: Date
}

/// Handles `SCStreamOutput` and `SCStreamDelegate` callbacks and drives `AVAssetWriter`.
///
/// Marked `@unchecked Sendable` because all mutable writer state (`sessionStarted`,
/// `frameCount`, `lastPTS`, `writerError`, `isClosed`, and the underlying `AVAssetWriter`
/// objects) is strictly confined to the serial `sampleQueue` after initialization.
private final class StreamOutputHandler: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let outputURL: URL
    private let sampleQueue: DispatchQueue
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor

    private var sessionStarted = false
    private var frameCount = 0
    private var lastPTS: CMTime = .invalid
    private var writerError: RecorderError?
    private var isClosed = false

    init(outputURL: URL, width: Int, height: Int, sampleQueue: DispatchQueue) throws {
        self.outputURL = outputURL
        self.sampleQueue = sampleQueue
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        do {
            self.writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw RecorderError.writerFailed(error.localizedDescription)
        }

        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        videoInput.expectsMediaDataInRealTime = true

        let sourceBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: sourceBufferAttributes
        )

        guard writer.canAdd(videoInput) else {
            throw RecorderError.writerFailed("Cannot add H.264 video input to AVAssetWriter")
        }
        writer.add(videoInput)

        guard writer.startWriting() else {
            let message = writer.error?.localizedDescription ?? "Failed to start AVAssetWriter"
            throw RecorderError.writerFailed(message)
        }

        self.input = videoInput
        self.adaptor = pixelBufferAdaptor
        super.init()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        sampleQueue.async { [weak self] in
            guard let self, !self.isClosed, self.writerError == nil else { return }
            self.writerError = .writerFailed(message)
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen, !isClosed, writerError == nil else { return }
        guard CMSampleBufferIsValid(sampleBuffer) else { return }

        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let rawStatus = attachments[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus),
              status == .complete else {
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid && !pts.isIndefinite else { return }

        if !sessionStarted {
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
        } else if lastPTS.isValid && pts <= lastPTS {
            return
        }

        guard input.isReadyForMoreMediaData else { return }

        if adaptor.append(pixelBuffer, withPresentationTime: pts) {
            lastPTS = pts
            frameCount += 1
        } else {
            let message = writer.error?.localizedDescription ?? "Failed to append pixel buffer"
            writerError = .writerFailed(message)
        }
    }

    func cancelAndCleanUp() {
        guard !isClosed else { return }
        isClosed = true
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: outputURL)
    }

    func finish(stopTime: CMTime, continuation: CheckedContinuation<URL, Error>) {
        guard !isClosed else {
            continuation.resume(throwing: RecorderError.notRecording)
            return
        }
        isClosed = true

        if let writerError {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            continuation.resume(throwing: writerError)
            return
        }

        guard sessionStarted && frameCount > 0 else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            continuation.resume(throwing: RecorderError.writerFailed("no frames"))
            return
        }

        let endPTS = CaptureGeometry.sessionEndTime(stopTime: stopTime, lastPTS: lastPTS)
        if endPTS.isValid && !endPTS.isIndefinite {
            writer.endSession(atSourceTime: endPTS)
        }
        input.markAsFinished()

        let writerBox = UncheckedSendableBox(value: writer)
        let url = outputURL
        writer.finishWriting {
            let completedWriter = writerBox.value
            if completedWriter.status == .completed {
                continuation.resume(returning: url)
            } else {
                let message = completedWriter.error?.localizedDescription
                    ?? "AVAssetWriter failed with status \(completedWriter.status.rawValue)"
                try? FileManager.default.removeItem(at: url)
                continuation.resume(throwing: RecorderError.writerFailed(message))
            }
        }
    }
}

/// Wraps a non-Sendable reference when bridging across an async completion boundary where
/// exclusive access is guaranteed by state machine ordering (`finishWriting` runs once after
/// `isClosed = true` on `sampleQueue`).
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}
