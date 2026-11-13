# record2gif — Product & Technical Spec

A native macOS app that records the screen (QuickTime-style "New Screen Recording" UX) and
exports the result **directly as an animated GIF**, with a choice of output resolution.

## 1. User stories

1. As a user I open record2gif and see a small floating control bar (like QuickTime's
   screen-recording bar): **Record Entire Screen**, **Record Selected Area**, an **Options** menu
   and a big red **Record** button.
2. If I pick "Selected Area", a dimmed full-screen overlay lets me drag a rectangle; it shows the
   size in pixels and can be adjusted before I hit Record.
3. While recording, a menu-bar item shows a stop icon + elapsed time. Clicking it, or pressing
   **⌃⌘Esc**, stops the recording. The control bar hides during recording so it isn't captured.
4. After stopping, an **Export** window opens with:
   - a looping preview of the recording,
   - **Resolution** picker: Original, 1280, 960, 640, 480, 320 px wide, or Custom width
     (aspect ratio is always kept; never upscaled),
   - **Frame rate** picker: 5, 10, 15 (default), 20, 30 fps,
   - **Loop forever** toggle (default on),
   - an estimated output size label (W×H, frame count),
   - **Save GIF…** (NSSavePanel, default name `Recording YYYY-MM-DD at HH.mm.ss.gif` on Desktop)
     and **Discard**. A progress bar is shown while encoding.
5. On first launch without Screen Recording permission, the app explains why and opens
   System Settings → Privacy & Security → Screen Recording.

Out of scope for v1: audio, trimming, webcam, editing, App Store sandboxing.

## 2. Tech stack

- Swift 6 toolchain, **Swift Package Manager** (no .xcodeproj), `swift-tools-version:5.10`,
  Swift language mode 5. Minimum **macOS 14**.
- UI: SwiftUI + AppKit where needed (NSPanel, NSStatusItem, overlay windows).
- Capture: **ScreenCaptureKit** (`SCStream`) → `AVAssetWriter` writes H.264 `.mov` to a temp dir.
- GIF: **AVFoundation** (`AVAssetImageGenerator`) to sample frames + **ImageIO**
  (`CGImageDestination`, `UTType.gif`) to encode. No third-party dependencies.
- Tests: Swift Testing (`import Testing`), run with `swift test`.
- `.app` bundle produced by `scripts/build-app.sh` (ad-hoc signed) so macOS can grant
  Screen Recording permission to a stable bundle id `com.kkdai.record2gif`.

## 3. Package layout (canonical — do not deviate)

```
Package.swift
Sources/
  Record2GifCore/              # library, no SwiftUI
    Capture/                   # issue #2
      CaptureTarget.swift
      ScreenRecorder.swift
    GIF/                       # issue #3
      GIFExportOptions.swift
      GIFExporter.swift
    Core.swift                 # issue #1 (version constant only)
  Record2Gif/                  # executable SwiftUI app
    Record2GifApp.swift        # issue #1
    AppModel.swift             # issue #1 (phase state machine)
    StatusItemController.swift # issue #1 (menu bar item)
    Recording/                 # issue #4
    Export/                    # issue #5
Tests/
  Record2GifCoreTests/
Resources/Info.plist           # issue #1
scripts/build-app.sh           # issue #1
Makefile                       # issue #1  (build / test / app / run)
```

Package.swift targets: `Record2GifCore` (library), `Record2Gif` (executableTarget, depends on
Core), `Record2GifCoreTests` (testTarget, depends on Core).

## 4. Core interfaces (contracts between issues)

### 4.1 Capture (`Record2GifCore/Capture`, issue #2)

```swift
public struct DisplayInfo: Identifiable, Hashable, Sendable {
    public let id: CGDirectDisplayID
    public let name: String
    public let frame: CGRect      // global AppKit coordinates (points)
    public let scale: CGFloat     // backing scale factor
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
}

@MainActor
public final class ScreenRecorder: ObservableObject {
    @Published public private(set) var isRecording: Bool
    @Published public private(set) var elapsed: TimeInterval
    public init()
    public static func hasPermission() -> Bool          // CGPreflightScreenCaptureAccess
    public static func requestPermission() -> Bool      // CGRequestScreenCaptureAccess
    public func availableDisplays() async throws -> [DisplayInfo]
    public func start(_ options: RecordingOptions) async throws
    public func stop() async throws -> URL              // finished .mov in temp dir
}

public enum RecorderError: Error { case permissionDenied, displayNotFound, alreadyRecording,
                                   notRecording, writerFailed(String) }
```

Output video is captured at **native pixel resolution** (points × scale); downscaling
happens only at GIF export time.

### 4.2 GIF export (`Record2GifCore/GIF`, issue #3)

```swift
public enum GIFResolution: Hashable, Sendable, CaseIterable, Identifiable {
    case original, w1280, w960, w640, w480, w320
    case custom(Int)
    public static var allCases: [GIFResolution]        // excludes .custom
    public var maxWidth: Int?                          // nil for .original
    public var label: String                           // "Original", "1280 px", …
}

public struct GIFExportOptions: Hashable, Sendable {
    public var resolution: GIFResolution = .w960
    public var fps: Int = 15                            // clamped to 1...50
    public var loopForever: Bool = true
    public init(...)
}

public enum GIFSizing {
    /// Keeps aspect ratio, never upscales, rounds to even integers, min 2×2.
    public static func outputSize(source: CGSize, resolution: GIFResolution) -> CGSize
    public static func frameCount(duration: TimeInterval, fps: Int) -> Int
}

public final class GIFExporter: Sendable {
    public init()
    public func export(video: URL, to output: URL, options: GIFExportOptions,
                       progress: @escaping @Sendable (Double) -> Void) async throws
}

public enum GIFExportError: Error { case noVideoTrack, frameExtractionFailed, encodeFailed,
                                    cancelled }
```

GIF frame delay = `1 / fps` (`kCGImagePropertyGIFDelayTime` and `UnclampedDelayTime`);
`kCGImagePropertyGIFLoopCount = 0` when `loopForever`, else 1. Export honours Task cancellation.

### 4.3 App state (`Record2Gif/AppModel.swift`, issue #1)

```swift
@MainActor final class AppModel: ObservableObject {
    enum Phase: Equatable { case idle, selectingArea, recording, exporting(URL) }
    @Published var phase: Phase = .idle
    let recorder = ScreenRecorder()           // stub until #2 lands
}
```

`Record2GifApp` routes on `phase`: idle/selectingArea → `RecordingControlView` (issue #4),
exporting → `ExportView(videoURL:)` (issue #5). Issue #1 ships placeholder versions of both
views at `Recording/RecordingControlView.swift` and `Export/ExportView.swift`; #4 and #5 replace
them. Only #4 may edit `Recording/`, only #5 may edit `Export/`.

## 5. Issues and order

| # | Title | Depends on | Round |
|---|-------|-----------|-------|
| 1 | Project scaffold, app shell, bundle script | – | 1 |
| 2 | ScreenCaptureKit recorder engine | 1 | 2 (pane A) |
| 3 | GIF exporter with resolution/fps options | 1 | 2 (pane B) |
| 4 | QuickTime-style recording UI | 1, 2 | 3 (pane A) |
| 5 | Export window: resolution picker, preview, save | 1, 3 | 3 (pane B) |

Each issue is implemented by a coder agent in its own git worktree/branch; Claude Code (PM)
reviews, commits, merges to `main` and closes the issue.

## 6. Definition of done (every issue)

- `swift build` and `swift test` pass with no new warnings in touched files.
- `make app` produces `build/record2gif.app` (from #1 onward).
- No files changed outside the issue's scope.
- No debug prints, no secrets, no force-unwraps on user/system input.
