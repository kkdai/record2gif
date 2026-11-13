import CoreGraphics
import CoreMedia
import Testing
@testable import Record2GifCore

@Suite("Capture Geometry & Recorder Tests")
struct CaptureTests {
    @Test("roundToEven produces even dimensions with minimum 2")
    func roundToEvenValues() {
        #expect(CaptureGeometry.roundToEven(1920) == 1920)
        #expect(CaptureGeometry.roundToEven(1921) == 1920)
        #expect(CaptureGeometry.roundToEven(1080.4) == 1080)
        #expect(CaptureGeometry.roundToEven(1080.6) == 1080)
        #expect(CaptureGeometry.roundToEven(3) == 2)
        #expect(CaptureGeometry.roundToEven(1) == 2)
        #expect(CaptureGeometry.roundToEven(0) == 2)
        #expect(CaptureGeometry.roundToEven(-50) == 2)
        #expect(CaptureGeometry.roundToEven(.nan) == 2)
        #expect(CaptureGeometry.roundToEven(.infinity) == 2)
    }

    @Test("pixelDimensions for full display multiplies points by scale and rounds to even")
    func displayPixelDimensions() {
        let displayID: CGDirectDisplayID = 42
        let target = CaptureTarget.display(displayID)

        // Retina 2x display with even point dimensions
        let retina = CaptureGeometry.pixelDimensions(
            for: target,
            displayPointSize: CGSize(width: 1512, height: 982),
            scale: 2.0
        )
        #expect(retina.width == 3024)
        #expect(retina.height == 1964)
        #expect(retina.sourceRect == nil)

        // 1x display with odd point dimensions rounds down to even
        let standardOdd = CaptureGeometry.pixelDimensions(
            for: target,
            displayPointSize: CGSize(width: 1365, height: 767),
            scale: 1.0
        )
        #expect(standardOdd.width == 1364)
        #expect(standardOdd.height == 766)
        #expect(standardOdd.sourceRect == nil)
    }

    @Test("pixelDimensions for area preserves sourceRect and scales rect size to even")
    func areaPixelDimensions() {
        let displayID: CGDirectDisplayID = 7
        let rect = CGRect(x: 100.5, y: 50.0, width: 401, height: 299)
        let target = CaptureTarget.area(display: displayID, rect: rect)
        let displaySize = CGSize(width: 1440, height: 900)

        // 1x scale: 401 -> 400, 299 -> 298
        let dims1x = CaptureGeometry.pixelDimensions(
            for: target,
            displayPointSize: displaySize,
            scale: 1.0
        )
        #expect(dims1x.width == 400)
        #expect(dims1x.height == 298)
        #expect(dims1x.sourceRect == rect)

        // 2x scale: 401 * 2 = 802, 299 * 2 = 598
        let dims2x = CaptureGeometry.pixelDimensions(
            for: target,
            displayPointSize: displaySize,
            scale: 2.0
        )
        #expect(dims2x.width == 802)
        #expect(dims2x.height == 598)
        #expect(dims2x.sourceRect == rect)

        // Fractional rect at 2x: 150.5 * 2 = 301 -> 300, 99.5 * 2 = 199 -> 198
        let fractionalRect = CGRect(x: 10, y: 20, width: 150.5, height: 99.5)
        let fractionalDims = CaptureGeometry.pixelDimensions(
            for: .area(display: displayID, rect: fractionalRect),
            displayPointSize: displaySize,
            scale: 2.0
        )
        #expect(fractionalDims.width == 300)
        #expect(fractionalDims.height == 198)
        #expect(fractionalDims.sourceRect == fractionalRect)
    }

    @Test("pixelDimensions handles non-positive or invalid scale by falling back to 1.0")
    func invalidScaleFallback() {
        let target = CaptureTarget.display(1)
        let size = CGSize(width: 800, height: 600)

        #expect(CaptureGeometry.pixelDimensions(for: target, displayPointSize: size, scale: 0).width == 800)
        #expect(CaptureGeometry.pixelDimensions(for: target, displayPointSize: size, scale: -2).height == 600)
        #expect(CaptureGeometry.pixelDimensions(for: target, displayPointSize: size, scale: .nan).width == 800)
    }

    @Test("displayID extracts target display identifier")
    func extractDisplayID() {
        #expect(CaptureGeometry.displayID(for: .display(10)) == 10)
        #expect(CaptureGeometry.displayID(for: .area(display: 99, rect: CGRect(x: 0, y: 0, width: 50, height: 50))) == 99)
    }

    @Test("frameInterval builds CMTime(1, fps) and clamps invalid fps to 1")
    func frameIntervalComputation() {
        let interval30 = CaptureGeometry.frameInterval(fps: 30)
        #expect(interval30 == CMTime(value: 1, timescale: 30))

        let interval60 = CaptureGeometry.frameInterval(fps: 60)
        #expect(interval60 == CMTime(value: 1, timescale: 60))

        let intervalZero = CaptureGeometry.frameInterval(fps: 0)
        #expect(intervalZero == CMTime(value: 1, timescale: 1))

        let intervalNegative = CaptureGeometry.frameInterval(fps: -15)
        #expect(intervalNegative == CMTime(value: 1, timescale: 1))
    }

    @Test("appKitFrame converts CoreGraphics top-left origin to AppKit bottom-left origin")
    func appKitFrameConversion() {
        let primaryScreen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(CaptureGeometry.appKitFrame(fromCGFrame: primaryScreen, primaryScreenHeight: 982) == primaryScreen)

        // Secondary display positioned above primary in CG coordinates (y = -1080, height = 1080)
        // In AppKit coordinates: y = 982 - (-1080 + 1080) = 982
        let upperDisplayCG = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        let upperDisplayAppKit = CaptureGeometry.appKitFrame(fromCGFrame: upperDisplayCG, primaryScreenHeight: 982)
        #expect(upperDisplayAppKit == CGRect(x: 0, y: 982, width: 1920, height: 1080))
    }

    @Test("sessionEndTime takes max(stopTime, lastPTS)")
    func sessionEndTimeComputation() {
        let pts2s = CMTime(seconds: 2.0, preferredTimescale: 600)
        let stop10s = CMTime(seconds: 10.0, preferredTimescale: 600)
        #expect(CaptureGeometry.sessionEndTime(stopTime: stop10s, lastPTS: pts2s) == stop10s)
        #expect(CaptureGeometry.sessionEndTime(stopTime: pts2s, lastPTS: stop10s) == stop10s)
        #expect(CaptureGeometry.sessionEndTime(stopTime: .invalid, lastPTS: pts2s) == pts2s)
    }

    @Test("ScreenRecorder initial state and stop guard when not recording")
    @MainActor
    func recorderInitialStateAndStopGuard() async {
        let recorder = ScreenRecorder()
        #expect(recorder.isRecording == false)
        #expect(recorder.elapsed == 0)

        await #expect(throws: RecorderError.notRecording) {
            _ = try await recorder.stop()
        }
    }
}
