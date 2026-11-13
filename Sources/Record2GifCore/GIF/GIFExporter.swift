import Foundation

public final class GIFExporter: Sendable {
    public init() {}

    public func export(
        video: URL,
        to output: URL,
        options: GIFExportOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        fatalError("not implemented")
    }
}

public enum GIFExportError: Error, Equatable, Sendable {
    case noVideoTrack
    case frameExtractionFailed
    case encodeFailed
    case cancelled
}
