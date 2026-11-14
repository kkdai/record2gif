import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

public final class GIFExporter: Sendable {
    public init() {}

    public func export(
        video: URL,
        to output: URL,
        options: GIFExportOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try Self.checkCancellation()

        let asset = AVURLAsset(url: video)
        let videoTrack: AVAssetTrack
        let durationTime: CMTime
        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform

        do {
            let (tracks, loadedDuration) = try await asset.load(.tracks, .duration)
            try Self.checkCancellation()
            guard let track = tracks.first(where: { $0.mediaType == .video }) else {
                throw GIFExportError.noVideoTrack
            }
            videoTrack = track
            durationTime = loadedDuration
            (naturalSize, preferredTransform) = try await videoTrack.load(.naturalSize, .preferredTransform)
        } catch let error as GIFExportError {
            throw error
        } catch is CancellationError {
            throw GIFExportError.cancelled
        } catch {
            if Task.isCancelled {
                throw GIFExportError.cancelled
            }
            throw GIFExportError.noVideoTrack
        }

        try Self.checkCancellation()

        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let sourceSize = CGSize(
            width: abs(transformedRect.width),
            height: abs(transformedRect.height)
        )
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            throw GIFExportError.noVideoTrack
        }

        let durationSeconds = max(0, CMTimeGetSeconds(durationTime))
        guard durationSeconds.isFinite else {
            throw GIFExportError.noVideoTrack
        }

        let fps = min(max(options.fps, 1), 50)
        let outputSize = GIFSizing.outputSize(source: sourceSize, resolution: options.resolution)
        let totalFrames = GIFSizing.frameCount(duration: durationSeconds, fps: fps)
        let frameDelay = 1.0 / Double(fps)

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw GIFExportError.frameExtractionFailed
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(trackOutput) else {
            throw GIFExportError.frameExtractionFailed
        }
        reader.add(trackOutput)
        guard reader.startReading() else {
            throw GIFExportError.frameExtractionFailed
        }
        defer {
            if reader.status == .reading {
                reader.cancelReading()
            }
        }

        let fileManager = FileManager.default
        let outputDirectory = output.deletingLastPathComponent()
        let tempWorkDir = fileManager.temporaryDirectory
            .appendingPathComponent("record2gif-export-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: tempWorkDir, withIntermediateDirectories: true)
        } catch {
            try? fileManager.removeItem(at: tempWorkDir)
            throw GIFExportError.encodeFailed
        }

        let tempURL = tempWorkDir.appendingPathComponent(output.lastPathComponent)
        defer {
            try? fileManager.removeItem(at: tempWorkDir)
        }

        do {
            guard let destination = CGImageDestinationCreateWithURL(
                tempURL as CFURL,
                UTType.gif.identifier as CFString,
                totalFrames,
                nil
            ) else {
                throw GIFExportError.encodeFailed
            }

            let loopCount = options.loopForever ? 0 : 1
            let fileProperties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFLoopCount: loopCount
                ]
            ]
            CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

            let frameProperties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: frameDelay,
                    kCGImagePropertyGIFUnclampedDelayTime: frameDelay
                ]
            ]

            progress(0.0)

            func readNextSample() throws -> DecodedSample? {
                while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
                    try Self.checkCancellation()
                    if CMSampleBufferGetImageBuffer(sampleBuffer) != nil {
                        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                        return DecodedSample(pts: pts, sampleBuffer: sampleBuffer)
                    }
                }
                try Self.checkCancellation()
                if reader.status == .failed {
                    throw GIFExportError.frameExtractionFailed
                }
                return nil
            }

            guard var currentSample = try readNextSample() else {
                throw GIFExportError.frameExtractionFailed
            }
            var nextSample = try readNextSample()
            let tolerance = CMTime(value: 1, timescale: 100_000)

            for frameIndex in 0..<totalFrames {
                try Self.checkCancellation()

                let targetTime = CMTime(
                    value: CMTimeValue(frameIndex * 600),
                    timescale: CMTimeScale(fps * 600)
                )
                let targetWithTolerance = CMTimeAdd(targetTime, tolerance)

                while let candidate = nextSample,
                      CMTimeCompare(candidate.pts, targetWithTolerance) <= 0 {
                    currentSample = candidate
                    nextSample = try readNextSample()
                }

                try Self.checkCancellation()

                let frameImage = try currentSample.renderedImage(
                    outputSize: outputSize,
                    preferredTransform: preferredTransform
                )
                CGImageDestinationAddImage(destination, frameImage, frameProperties as CFDictionary)
                progress(Double(frameIndex + 1) / Double(totalFrames))
            }

            try Self.checkCancellation()

            guard CGImageDestinationFinalize(destination) else {
                throw GIFExportError.encodeFailed
            }
        }

        try Self.checkCancellation()

        do {
            if fileManager.fileExists(atPath: output.path) {
                _ = try fileManager.replaceItemAt(output, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: output)
            }
        } catch {
            throw GIFExportError.encodeFailed
        }
    }

    private static func checkCancellation() throws {
        do {
            try Task.checkCancellation()
        } catch {
            throw GIFExportError.cancelled
        }
    }

    fileprivate static func renderAndScale(
        sampleBuffer: CMSampleBuffer,
        to targetSize: CGSize,
        preferredTransform: CGAffineTransform
    ) throws -> CGImage {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw GIFExportError.frameExtractionFailed
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw GIFExportError.frameExtractionFailed
        }

        let rawWidth = CVPixelBufferGetWidth(pixelBuffer)
        let rawHeight = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard rawWidth > 0, rawHeight > 0 else {
            throw GIFExportError.frameExtractionFailed
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue

        guard let sourceContext = CGContext(
            data: baseAddress,
            width: rawWidth,
            height: rawHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ), let rawImage = sourceContext.makeImage() else {
            throw GIFExportError.frameExtractionFailed
        }

        let targetWidth = max(2, Int(targetSize.width.rounded()))
        let targetHeight = max(2, Int(targetSize.height.rounded()))

        guard let destContext = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw GIFExportError.frameExtractionFailed
        }

        destContext.interpolationQuality = .high

        if preferredTransform.isIdentity {
            destContext.draw(rawImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        } else {
            let rawSize = CGSize(width: rawWidth, height: rawHeight)
            let transformedBounds = CGRect(origin: .zero, size: rawSize).applying(preferredTransform)
            let orientedWidth = max(1, abs(transformedBounds.width))
            let orientedHeight = max(1, abs(transformedBounds.height))
            let normalizedTransform = preferredTransform.concatenating(
                CGAffineTransform(translationX: -transformedBounds.minX, y: -transformedBounds.minY)
            )

            destContext.scaleBy(
                x: CGFloat(targetWidth) / orientedWidth,
                y: CGFloat(targetHeight) / orientedHeight
            )
            destContext.translateBy(x: 0, y: orientedHeight)
            destContext.scaleBy(x: 1, y: -1)
            destContext.concatenate(normalizedTransform)
            destContext.translateBy(x: 0, y: rawSize.height)
            destContext.scaleBy(x: 1, y: -1)
            destContext.draw(rawImage, in: CGRect(origin: .zero, size: rawSize))
        }

        guard let outputImage = destContext.makeImage() else {
            throw GIFExportError.frameExtractionFailed
        }
        return outputImage
    }
}

private struct DecodedSample {
    let pts: CMTime
    let sampleBuffer: CMSampleBuffer
    private var cachedImage: CGImage?

    init(pts: CMTime, sampleBuffer: CMSampleBuffer) {
        self.pts = pts
        self.sampleBuffer = sampleBuffer
    }

    mutating func renderedImage(
        outputSize: CGSize,
        preferredTransform: CGAffineTransform
    ) throws -> CGImage {
        if let cachedImage {
            return cachedImage
        }
        let image = try GIFExporter.renderAndScale(
            sampleBuffer: sampleBuffer,
            to: outputSize,
            preferredTransform: preferredTransform
        )
        cachedImage = image
        return image
    }
}

public enum GIFExportError: Error, LocalizedError, Equatable, Sendable {
    case noVideoTrack
    case frameExtractionFailed
    case encodeFailed
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "The recording does not contain a readable video track."
        case .frameExtractionFailed:
            return "Failed to decode frames from the recording."
        case .encodeFailed:
            return "Failed to encode the animated GIF file."
        case .cancelled:
            return "GIF export was cancelled."
        }
    }
}
