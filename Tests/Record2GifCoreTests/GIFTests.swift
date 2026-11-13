import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Record2GifCore

@Suite("GIF Sizing & Options Tests")
struct GIFSizingTests {
    @Test("GIFResolution metadata and cases")
    func resolutionMetadata() {
        #expect(GIFResolution.allCases == [.original, .w1280, .w960, .w640, .w480, .w320])
        #expect(GIFResolution.original.maxWidth == nil)
        #expect(GIFResolution.w1280.maxWidth == 1280)
        #expect(GIFResolution.w960.maxWidth == 960)
        #expect(GIFResolution.w640.maxWidth == 640)
        #expect(GIFResolution.w480.maxWidth == 480)
        #expect(GIFResolution.w320.maxWidth == 320)
        #expect(GIFResolution.custom(500).maxWidth == 500)

        #expect(GIFResolution.original.label == "Original")
        #expect(GIFResolution.w960.label == "960 px")
        #expect(GIFResolution.custom(720).label == "720 px")
    }

    @Test("GIFExportOptions clamps fps to 1...50")
    func optionsClamping() {
        let low = GIFExportOptions(fps: 0)
        #expect(low.fps == 1)

        let high = GIFExportOptions(fps: 120)
        #expect(high.fps == 50)

        var mutable = GIFExportOptions(fps: 15)
        mutable.fps = -10
        #expect(mutable.fps == 1)
        mutable.fps = 99
        #expect(mutable.fps == 50)
    }

    @Test("outputSize table: original, downscale, no upscale, odd -> even, portrait, custom, invalid custom")
    func outputSizeTable() {
        // Original keeps dimensions
        #expect(
            GIFSizing.outputSize(source: CGSize(width: 1920, height: 1080), resolution: .original)
            == CGSize(width: 1920, height: 1080)
        )

        // Downscale 16:9
        #expect(
            GIFSizing.outputSize(source: CGSize(width: 1920, height: 1080), resolution: .w1280)
            == CGSize(width: 1280, height: 720)
        )
        #expect(
            GIFSizing.outputSize(source: CGSize(width: 1920, height: 1080), resolution: .w960)
            == CGSize(width: 960, height: 540)
        )
        #expect(
            GIFSizing.outputSize(source: CGSize(width: 1920, height: 1080), resolution: .w640)
            == CGSize(width: 640, height: 360)
        )
        #expect(
            GIFSizing.outputSize(source: CGSize(width: 1920, height: 1080), resolution: .w480)
            == CGSize(width: 480, height: 270)
        )
        #expect(
            GIFSizing.outputSize(source: CGSize(width: 1920, height: 1080), resolution: .w320)
            == CGSize(width: 320, height: 180)
        )

        // No upscale when source is smaller than preset
        #expect(
            GIFSizing.outputSize(source: CGSize(width: 640, height: 360), resolution: .w1280)
            == CGSize(width: 640, height: 360)
        )
        #expect(
            GIFSizing.outputSize(source: CGSize(width: 640, height: 360), resolution: .custom(1000))
            == CGSize(width: 640, height: 360)
        )

        // Odd -> even rounding & minimum 2x2 (never upscales on odd dimensions)
        #expect(
            GIFSizing.outputSize(source: CGSize(width: 1365, height: 767), resolution: .original)
            == CGSize(width: 1364, height: 766)
        )

        let oddResult = GIFSizing.outputSize(
            source: CGSize(width: 1000, height: 563),
            resolution: .w640
        )
        #expect(Int(oddResult.width) % 2 == 0)
        #expect(Int(oddResult.height) % 2 == 0)
        #expect(oddResult == CGSize(width: 640, height: 360))

        let tinyResult = GIFSizing.outputSize(
            source: CGSize(width: 1, height: 1),
            resolution: .original
        )
        #expect(tinyResult == CGSize(width: 2, height: 2))

        // Portrait keeps aspect ratio based on width
        #expect(
            GIFSizing.outputSize(source: CGSize(width: 600, height: 1000), resolution: .w480)
            == CGSize(width: 480, height: 800)
        )
        #expect(
            GIFSizing.outputSize(source: CGSize(width: 360, height: 640), resolution: .w480)
            == CGSize(width: 360, height: 640)
        )

        // Custom valid width
        #expect(
            GIFSizing.outputSize(source: CGSize(width: 1200, height: 600), resolution: .custom(500))
            == CGSize(width: 500, height: 250)
        )

        // Invalid custom (<= 0) treated as original
        #expect(
            GIFSizing.outputSize(source: CGSize(width: 640, height: 360), resolution: .custom(0))
            == CGSize(width: 640, height: 360)
        )
        #expect(
            GIFSizing.outputSize(source: CGSize(width: 640, height: 360), resolution: .custom(-320))
            == CGSize(width: 640, height: 360)
        )
    }

    @Test("frameCount calculations")
    func frameCountCalculations() {
        #expect(GIFSizing.frameCount(duration: 2.0, fps: 10) == 20)
        #expect(GIFSizing.frameCount(duration: 2.0, fps: 15) == 30)
        #expect(GIFSizing.frameCount(duration: 1.99, fps: 10) == 19)
        #expect(GIFSizing.frameCount(duration: 0.01, fps: 10) == 1)
        #expect(GIFSizing.frameCount(duration: 0.0, fps: 15) == 1)
        #expect(GIFSizing.frameCount(duration: -1.0, fps: 15) == 1)
    }
}

@Suite("GIF Exporter Integration Tests")
struct GIFExporterTests {
    @Test("Export 2s 640x360 30fps video to .w320 at 10fps with loopForever=true")
    func exportStandardGIF() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("record2gif-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let videoURL = tempDir.appendingPathComponent("input.mov")
        let gifURL = tempDir.appendingPathComponent("output.gif")

        try await Self.generateTestVideo(
            at: videoURL,
            width: 640,
            height: 360,
            fps: 30,
            durationSeconds: 2.0
        )

        let exporter = GIFExporter()
        let progressRecorder = ProgressRecorder()
        let options = GIFExportOptions(resolution: .w320, fps: 10, loopForever: true)

        try await exporter.export(video: videoURL, to: gifURL, options: options) { value in
            progressRecorder.record(value)
        }

        #expect(FileManager.default.fileExists(atPath: gifURL.path))

        let values = progressRecorder.values
        #expect(!values.isEmpty)
        if let last = values.last {
            #expect(abs(last - 1.0) < 0.001)
        }

        guard let source = CGImageSourceCreateWithURL(gifURL as CFURL, nil) else {
            Issue.record("Failed to open exported GIF with CGImageSource")
            return
        }

        let sourceType = CGImageSourceGetType(source) as String?
        #expect(sourceType == UTType.gif.identifier)

        let count = CGImageSourceGetCount(source)
        #expect(abs(count - 20) <= 1)

        guard let firstFrame = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Issue.record("Failed to decode first GIF frame")
            return
        }
        #expect(firstFrame.width == 320)
        #expect(firstFrame.height == 180)

        let fileProps = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let fileGIFDict = fileProps?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let loopCount = fileGIFDict?[kCGImagePropertyGIFLoopCount] as? Int
        #expect(loopCount == 0)

        let frameProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let frameGIFDict = frameProps?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let delay = (frameGIFDict?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (frameGIFDict?[kCGImagePropertyGIFDelayTime] as? Double)
        #expect(delay != nil)
        if let delay {
            #expect(abs(delay - 0.1) < 0.02)
        }
    }

    @Test("Export with loopForever=false sets GIF loop count to 1")
    func exportLoopOnceGIF() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("record2gif-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let videoURL = tempDir.appendingPathComponent("input.mov")
        let gifURL = tempDir.appendingPathComponent("loop-once.gif")

        try await Self.generateTestVideo(
            at: videoURL,
            width: 640,
            height: 360,
            fps: 30,
            durationSeconds: 1.0
        )

        let exporter = GIFExporter()
        let options = GIFExportOptions(resolution: .w320, fps: 10, loopForever: false)
        try await exporter.export(video: videoURL, to: gifURL, options: options) { _ in }

        guard let source = CGImageSourceCreateWithURL(gifURL as CFURL, nil) else {
            Issue.record("Failed to open exported GIF")
            return
        }

        let fileProps = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let fileGIFDict = fileProps?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let loopCount = fileGIFDict?[kCGImagePropertyGIFLoopCount] as? Int
        #expect(loopCount == 1)
    }

    @Test("Export honours Task cancellation and cleans up partial file")
    func exportCancellation() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("record2gif-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let videoURL = tempDir.appendingPathComponent("input.mov")
        let gifURL = tempDir.appendingPathComponent("cancelled.gif")

        try await Self.generateTestVideo(
            at: videoURL,
            width: 640,
            height: 360,
            fps: 30,
            durationSeconds: 2.0
        )

        let exporter = GIFExporter()
        let options = GIFExportOptions(resolution: .w320, fps: 30, loopForever: true)

        let taskBox = TaskBox()
        let task = Task {
            try await exporter.export(video: videoURL, to: gifURL, options: options) { progress in
                if progress > 0 {
                    taskBox.cancel()
                }
            }
        }
        taskBox.set(task)

        await #expect(throws: GIFExportError.cancelled) {
            try await task.value
        }

        #expect(!FileManager.default.fileExists(atPath: gifURL.path))
        let remainingFiles = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
        #expect(remainingFiles == ["input.mov"])
    }

    private static func generateTestVideo(
        at url: URL,
        width: Int,
        height: Int,
        fps: Int,
        durationSeconds: Double
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )

        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let totalFrames = Int(durationSeconds * Double(fps))
        for frameIndex in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw GIFExportError.encodeFailed
            }
            var pixelBufferOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
            guard let pixelBuffer = pixelBufferOut else {
                throw GIFExportError.encodeFailed
            }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                if let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                ) {
                    let hue = CGFloat(frameIndex) / CGFloat(max(1, totalFrames))
                    context.setFillColor(
                        red: hue,
                        green: 0.5,
                        blue: 1.0 - hue,
                        alpha: 1.0
                    )
                    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
            adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
        }

        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error {
            throw error
        }
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Error>?
    private var shouldCancel = false

    func set(_ task: Task<Void, Error>) {
        lock.lock()
        self.task = task
        let cancelNow = shouldCancel
        lock.unlock()
        if cancelNow {
            task.cancel()
        }
    }

    func cancel() {
        lock.lock()
        shouldCancel = true
        let currentTask = task
        lock.unlock()
        currentTask?.cancel()
    }
}
