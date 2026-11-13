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
    public var fps: Int = 15                            // clamped to 1...50
    public var loopForever: Bool = true

    public init(
        resolution: GIFResolution = .w960,
        fps: Int = 15,
        loopForever: Bool = true
    ) {
        self.resolution = resolution
        self.fps = min(max(fps, 1), 50)
        self.loopForever = loopForever
    }
}

public enum GIFSizing {
    /// Keeps aspect ratio, never upscales, rounds to even integers, min 2×2.
    public static func outputSize(source: CGSize, resolution: GIFResolution) -> CGSize {
        fatalError("not implemented")
    }

    public static func frameCount(duration: TimeInterval, fps: Int) -> Int {
        fatalError("not implemented")
    }
}
