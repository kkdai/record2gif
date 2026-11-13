import AVFoundation
import CoreGraphics
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

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = outputSize
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

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

            var times: [CMTime] = []
            times.reserveCapacity(totalFrames)
            var timeToIndex: [CMTime: Int] = [:]
            timeToIndex.reserveCapacity(totalFrames)

            for frameIndex in 0..<totalFrames {
                let requestedTime = CMTime(
                    value: CMTimeValue(frameIndex * 600),
                    timescale: CMTimeScale(fps * 600)
                )
                times.append(requestedTime)
                timeToIndex[requestedTime] = frameIndex
            }

            var pendingFrames: [Int: CGImage] = [:]
            var nextFrameToWrite = 0
            var completedCount = 0

            for await result in generator.images(for: times) {
                try Self.checkCancellation()

                let rawImage: CGImage
                do {
                    rawImage = try result.image
                } catch is CancellationError {
                    throw GIFExportError.cancelled
                } catch {
                    if Task.isCancelled {
                        throw GIFExportError.cancelled
                    }
                    throw GIFExportError.frameExtractionFailed
                }

                try Self.checkCancellation()

                let normalizedImage = try Self.ensureSize(rawImage, matches: outputSize)
                let frameIndex = timeToIndex[result.requestedTime]
                    ?? times.firstIndex(where: { CMTimeCompare($0, result.requestedTime) == 0 })
                    ?? nextFrameToWrite
                pendingFrames[frameIndex] = normalizedImage

                while let readyImage = pendingFrames.removeValue(forKey: nextFrameToWrite) {
                    CGImageDestinationAddImage(destination, readyImage, frameProperties as CFDictionary)
                    nextFrameToWrite += 1
                }

                completedCount += 1
                progress(Double(completedCount) / Double(totalFrames))
            }

            try Self.checkCancellation()

            guard nextFrameToWrite == totalFrames else {
                throw GIFExportError.frameExtractionFailed
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

    private static func ensureSize(_ image: CGImage, matches targetSize: CGSize) throws -> CGImage {
        let targetWidth = max(2, Int(targetSize.width.rounded()))
        let targetHeight = max(2, Int(targetSize.height.rounded()))
        if image.width == targetWidth && image.height == targetHeight {
            return image
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? image.colorSpace
            ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
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

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let resized = context.makeImage() else {
            throw GIFExportError.frameExtractionFailed
        }
        return resized
    }
}

public enum GIFExportError: Error, Equatable, Sendable {
    case noVideoTrack
    case frameExtractionFailed
    case encodeFailed
    case cancelled
}
