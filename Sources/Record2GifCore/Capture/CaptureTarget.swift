import CoreGraphics
import Foundation

public struct DisplayInfo: Identifiable, Hashable, Sendable {
    public let id: CGDirectDisplayID
    public let name: String
    public let frame: CGRect      // global AppKit coordinates (points)
    public let scale: CGFloat     // backing scale factor

    public init(id: CGDirectDisplayID, name: String, frame: CGRect, scale: CGFloat) {
        self.id = id
        self.name = name
        self.frame = frame
        self.scale = scale
    }
}

public enum CaptureTarget: Hashable, Sendable {
    case display(CGDirectDisplayID)
    /// rect in points, display-local, top-left origin (ScreenCaptureKit sourceRect convention)
    case area(display: CGDirectDisplayID, rect: CGRect)
}

public struct RecordingOptions: Sendable {
    public var target: CaptureTarget
    public var fps: Int = 30
    public var showsCursor: Bool = true
    public var excludedWindowIDs: [CGWindowID] = []   // e.g. our own control panel

    public init(
        target: CaptureTarget,
        fps: Int = 30,
        showsCursor: Bool = true,
        excludedWindowIDs: [CGWindowID] = []
    ) {
        self.target = target
        self.fps = fps
        self.showsCursor = showsCursor
        self.excludedWindowIDs = excludedWindowIDs
    }
}
