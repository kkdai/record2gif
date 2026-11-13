import CoreGraphics
import Foundation
import Record2GifCore

enum ResolutionChoice: String, CaseIterable, Identifiable {
    case original
    case w1280
    case w960
    case w640
    case w480
    case w320
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: return GIFResolution.original.label
        case .w1280: return GIFResolution.w1280.label
        case .w960: return GIFResolution.w960.label
        case .w640: return GIFResolution.w640.label
        case .w480: return GIFResolution.w480.label
        case .w320: return GIFResolution.w320.label
        case .custom: return "Custom…"
        }
    }

    func toGIFResolution(customWidth: Int) -> GIFResolution {
        switch self {
        case .original: return .original
        case .w1280: return .w1280
        case .w960: return .w960
        case .w640: return .w640
        case .w480: return .w480
        case .w320: return .w320
        case .custom: return .custom(customWidth)
        }
    }
}

enum ExportHelpers {
    static let availableFPS: [Int] = [5, 10, 15, 20, 30]
    static let minCustomWidth: Int = 16

    static func defaultFileName(for date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Recording \(formatter.string(from: date)).gif"
    }

    static func clampCustomWidth(_ value: Int, sourceWidth: Int) -> Int {
        let maxAllowed = max(minCustomWidth, sourceWidth)
        return min(max(value, minCustomWidth), maxAllowed)
    }

    static func parseCustomWidth(_ text: String, fallback: Int, sourceWidth: Int) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(trimmed) else {
            return clampCustomWidth(fallback, sourceWidth: sourceWidth)
        }
        return clampCustomWidth(parsed, sourceWidth: sourceWidth)
    }

    static func sanitizeFPS(_ fps: Int) -> Int {
        availableFPS.contains(fps) ? fps : 15
    }

    static func formattedOutputSummary(
        source: CGSize,
        duration: TimeInterval,
        resolution: GIFResolution,
        fps: Int
    ) -> String {
        let outputSize = GIFSizing.outputSize(source: source, resolution: resolution)
        let frames = GIFSizing.frameCount(duration: duration, fps: fps)
        return "→ \(Int(outputSize.width))×\(Int(outputSize.height)) px · \(frames) frames"
    }

    static func formattedSourceSummary(source: CGSize, duration: TimeInterval) -> String {
        let width = Int(source.width.rounded())
        let height = Int(source.height.rounded())
        let durationText = String(format: "%.1fs", max(0, duration))
        return "\(width)×\(height) px · \(durationText)"
    }
}
