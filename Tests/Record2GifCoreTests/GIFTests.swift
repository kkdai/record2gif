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

    @Test("GIFExportError provides human-readable LocalizedError descriptions")
    func errorDescriptions() {
        let errors: [GIFExportError] = [
            .noVideoTrack,
            .frameExtractionFailed,
            .encodeFailed,
            .cancelled
        ]
        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(!error.localizedDescription.contains("GIFExportError error"))
        }
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

    @Test("Export VFR video with irregular PTS, long gap, and extended endSession at 10 and 20 fps")
    func exportVFRVideoHoldsFramesAcrossGaps() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("record2gif-vfr-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let videoURL = tempDir.appendingPathComponent("vfr.mov")
        let samples: [(seconds: Double, r: CGFloat, g: CGFloat, b: CGFloat)] = [
            (0.00, 0.0, 0.0, 1.0), // initial blue
            (0.05, 0.0, 0.0, 1.0), // blue
            (0.10, 1.0, 0.0, 0.0), // red before 1.5s gap (held across 0.10..<1.60)
            (1.60, 0.0, 1.0, 0.0), // green burst start
            (1.63, 0.0, 1.0, 0.0),
            (1.67, 0.0, 1.0, 0.0),
            (1.72, 0.0, 0.0, 1.0)  // blue held until endSession (2.30s)
        ]
        let sessionEndSeconds = 2.30

        try await Self.generateVFRTestVideo(
            at: videoURL,
            width: 640,
            height: 360,
            samples: samples,
            endSessionSeconds: sessionEndSeconds
        )

        let asset = AVURLAsset(url: videoURL)
        let loadedDuration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(loadedDuration)

        let exporter = GIFExporter()

        for fps in [10, 20] {
            let gifURL = tempDir.appendingPathComponent("vfr-\(fps)fps.gif")
            let options = GIFExportOptions(resolution: .w320, fps: fps, loopForever: true)
            try await exporter.export(video: videoURL, to: gifURL, options: options) { _ in }

            guard let source = CGImageSourceCreateWithURL(gifURL as CFURL, nil) else {
                Issue.record("Failed to open VFR GIF at \(fps)fps")
                continue
            }

            let expectedCount = Int((durationSeconds * Double(fps)).rounded(.down))
            let actualCount = CGImageSourceGetCount(source)
            #expect(actualCount == expectedCount)

            // Frame at t = 0.10s (index 1 at 10fps, index 2 at 20fps) is the held RED frame
            let gapStartFrameIndex = fps == 10 ? 1 : 2
            // Frame at t = 0.80s (middle of the 1.5s gap: index 8 at 10fps, index 16 at 20fps)
            let midGapFrameIndex = fps == 10 ? 8 : 16
            // Frame at t = 1.40s (near end of the 1.5s gap: index 14 at 10fps, index 28 at 20fps)
            let lateGapFrameIndex = fps == 10 ? 14 : 28
            // Frame at t = 2.00s (in extended endSession tail: index 20 at 10fps, index 40 at 20fps)
            let tailFrameIndex = fps == 10 ? 20 : 40

            let heldStartRGB = try Self.sampleCenterPixel(from: source, at: gapStartFrameIndex)
            let midGapRGB = try Self.sampleCenterPixel(from: source, at: midGapFrameIndex)
            let lateGapRGB = try Self.sampleCenterPixel(from: source, at: lateGapFrameIndex)
            let tailRGB = try Self.sampleCenterPixel(from: source, at: tailFrameIndex)

            // Red dominant at gap start and held identically across the gap
            #expect(heldStartRGB.r > 200 && heldStartRGB.g < 50 && heldStartRGB.b < 50)
            #expect(midGapRGB == heldStartRGB)
            #expect(lateGapRGB == heldStartRGB)

            // Blue dominant in extended endSession tail
            #expect(tailRGB.b > 200 && tailRGB.r < 50 && tailRGB.g < 50)
        }

        // Also export at .original resolution (10fps) and verify EVERY frame's colour
        let originalGifURL = tempDir.appendingPathComponent("vfr-original-10fps.gif")
        let originalOptions = GIFExportOptions(resolution: .original, fps: 10, loopForever: true)
        try await exporter.export(video: videoURL, to: originalGifURL, options: originalOptions) { _ in }

        guard let originalSource = CGImageSourceCreateWithURL(originalGifURL as CFURL, nil) else {
            Issue.record("Failed to open VFR .original GIF")
            return
        }

        let expectedOriginalCount = Int((durationSeconds * 10.0).rounded(.down))
        let actualOriginalCount = CGImageSourceGetCount(originalSource)
        #expect(actualOriginalCount == expectedOriginalCount)

        if let firstOriginalFrame = CGImageSourceCreateImageAtIndex(originalSource, 0, nil) {
            #expect(firstOriginalFrame.width == 640)
            #expect(firstOriginalFrame.height == 360)
        }

        for frameIndex in 0..<actualOriginalCount {
            let t = Double(frameIndex) / 10.0
            let rgb = try Self.sampleCenterPixel(from: originalSource, at: frameIndex)
            if t < 0.099 {
                // 0.00..<0.10 -> Blue
                #expect(rgb.b > 200 && rgb.r < 50 && rgb.g < 50, "Frame \(frameIndex) at t=\(t) should be blue")
            } else if t < 1.599 {
                // 0.10..<1.60 -> Red (held across 1.5s gap)
                #expect(rgb.r > 200 && rgb.g < 50 && rgb.b < 50, "Frame \(frameIndex) at t=\(t) should be red")
            } else if t < 1.719 {
                // 1.60..<1.72 -> Green (burst)
                #expect(rgb.g > 200 && rgb.r < 50 && rgb.b < 50, "Frame \(frameIndex) at t=\(t) should be green")
            } else {
                // 1.72..<2.30 -> Blue (held through extended endSession)
                #expect(rgb.b > 200 && rgb.r < 50 && rgb.g < 50, "Frame \(frameIndex) at t=\(t) should be blue")
            }
        }
    }

    private static func sampleCenterPixel(
        from source: CGImageSource,
        at index: Int
    ) throws -> (r: UInt8, g: UInt8, b: UInt8) {
        guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
            throw GIFExportError.frameExtractionFailed
        }
        var pixel: [UInt8] = [0, 0, 0, 0]
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw GIFExportError.frameExtractionFailed
        }
        let centerX = CGFloat(image.width / 2)
        let centerY = CGFloat(image.height / 2)
        context.translateBy(x: -centerX, y: -centerY)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (pixel[0], pixel[1], pixel[2])
    }

    private static func generateVFRTestVideo(
        at url: URL,
        width: Int,
        height: Int,
        samples: [(seconds: Double, r: CGFloat, g: CGFloat, b: CGFloat)],
        endSessionSeconds: Double
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

        for sample in samples {
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
                    context.setFillColor(red: sample.r, green: sample.g, blue: sample.b, alpha: 1.0)
                    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            let pts = CMTime(seconds: sample.seconds, preferredTimescale: 600)
            adaptor.append(pixelBuffer, withPresentationTime: pts)
        }

        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: endSessionSeconds, preferredTimescale: 600))
        await writer.finishWriting()
        if let error = writer.error {
            throw error
        }
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
