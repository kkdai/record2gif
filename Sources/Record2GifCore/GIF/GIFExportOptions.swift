import CoreGraphics
import Foundation

public enum GIFResolution: Hashable, Sendable, CaseIterable, Identifiable {
    case original, w1280, w960, w640, w480, w320
    case custom(Int)

    public static var allCases: [GIFResolution] {
        [.original, .w1280, .w960, .w640, .w480, .w320]
    }

    public var id: Self { self }

    public var maxWidth: Int? {
        switch self {
        case .original: return nil
        case .w1280: return 1280
        case .w960: return 960
        case .w640: return 640
        case .w480: return 480
        case .w320: return 320
        case .custom(let width): return width
        }
    }

    public var label: String {
        switch self {
        case .original: return "Original"
        case .w1280: return "1280 px"
        case .w960: return "960 px"
        case .w640: return "640 px"
        case .w480: return "480 px"
        case .w320: return "320 px"
        case .custom(let width): return "\(width) px"
        }
    }
}

public struct GIFExportOptions: Hashable, Sendable {
    public var resolution: GIFResolution = .w960
    public var fps: Int = 15 {                          // clamped to 1...50
        didSet {
            let clamped = Self.clampFPS(fps)
            if fps != clamped {
                fps = clamped
            }
        }
    }
    public var loopForever: Bool = true

    public init(
        resolution: GIFResolution = .w960,
        fps: Int = 15,
        loopForever: Bool = true
    ) {
        self.resolution = resolution
        self.fps = Self.clampFPS(fps)
        self.loopForever = loopForever
    }

    private static func clampFPS(_ value: Int) -> Int {
        min(max(value, 1), 50)
    }
}

public enum GIFSizing {
    /// Keeps aspect ratio, never upscales, rounds to even integers, min 2×2.
    public static func outputSize(source: CGSize, resolution: GIFResolution) -> CGSize {
        guard source.width.isFinite, source.height.isFinite,
              source.width > 0, source.height > 0 else {
            return CGSize(width: 2, height: 2)
        }

        let scaledWidth: CGFloat
        let scaledHeight: CGFloat

        if let maxWidth = resolution.maxWidth, maxWidth > 0, CGFloat(maxWidth) < source.width {
            let scale = CGFloat(maxWidth) / source.width
            scaledWidth = CGFloat(maxWidth)
            scaledHeight = source.height * scale
        } else {
            scaledWidth = source.width
            scaledHeight = source.height
        }

        return CGSize(
            width: CGFloat(roundToEven(scaledWidth)),
            height: CGFloat(roundToEven(scaledHeight))
        )
    }

    public static func frameCount(duration: TimeInterval, fps: Int) -> Int {
        guard duration.isFinite, duration > 0, fps > 0 else { return 1 }
        return max(1, Int((duration * Double(fps)).rounded(.down)))
    }

    private static func roundToEven(_ value: CGFloat) -> Int {
        guard value.isFinite, value > 0 else { return 2 }
        var rounded = Int((value / 2.0).rounded()) * 2
        if CGFloat(rounded) > value {
            rounded -= 2
        }
        return max(2, rounded)
    }
}
