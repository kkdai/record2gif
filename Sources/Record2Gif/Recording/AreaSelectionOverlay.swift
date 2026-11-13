import AppKit
import Combine
import CoreGraphics
import Record2GifCore
import SwiftUI

@MainActor
final class AreaSelectionState: ObservableObject {
    struct Selection: Equatable {
        var displayID: CGDirectDisplayID
        /// Display-local rectangle in points with top-left origin (ScreenCaptureKit convention).
        var rect: CGRect
        var scale: CGFloat
    }

    @Published var activeSelection: Selection?

    var onConfirmRecord: ((CaptureTarget) -> Void)?
    var onCancel: (() -> Void)?

    func selectDefaultIfNeeded(on display: DisplayInfo) {
        guard activeSelection == nil else { return }
        let width = min(max(120, round(display.frame.width * 0.5)), display.frame.width)
        let height = min(max(90, round(display.frame.height * 0.5)), display.frame.height)
        let originX = round((display.frame.width - width) / 2.0)
        let originY = round((display.frame.height - height) / 2.0)
        activeSelection = Selection(
            displayID: display.id,
            rect: CGRect(x: originX, y: originY, width: width, height: height),
            scale: display.scale
        )
    }

    func currentCaptureTarget() -> CaptureTarget? {
        guard let selection = activeSelection else { return nil }
        let standardized = selection.rect.standardized
        guard standardized.width >= 8, standardized.height >= 8 else { return nil }
        return .area(display: selection.displayID, rect: standardized)
    }
}

/// Borderless full-screen panel at `.screenSaver` level that can become key to receive Esc / Return.
private final class AreaOverlayPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onReturn: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: // Esc
            onEscape?()
        case 36, 76: // Return / Enter
            onReturn?()
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

@MainActor
final class AreaSelectionOverlayController {
    private var panels: [AreaOverlayPanel] = []
    let state = AreaSelectionState()

    var overlayWindowIDs: [CGWindowID] {
        panels.compactMap { panel in
            panel.windowNumber > 0 ? CGWindowID(panel.windowNumber) : nil
        }
    }

    func present(
        displays: [DisplayInfo],
        preferredDisplayID: CGDirectDisplayID?,
        onConfirmRecord: @escaping (CaptureTarget) -> Void,
        onCancel: @escaping () -> Void
    ) {
        dismiss()

        state.onConfirmRecord = onConfirmRecord
        state.onCancel = onCancel

        let resolvedDisplays = displays.isEmpty ? Self.fallbackDisplaysFromNSScreens() : displays
        if let preferred = resolvedDisplays.first(where: { $0.id == preferredDisplayID }) ?? resolvedDisplays.first {
            state.selectDefaultIfNeeded(on: preferred)
        }

        for display in resolvedDisplays {
            let panel = AreaOverlayPanel(
                contentRect: display.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = false
            panel.acceptsMouseMovedEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.onEscape = { [weak self] in
                self?.state.onCancel?()
            }
            panel.onReturn = { [weak self] in
                guard let self, let target = self.state.currentCaptureTarget() else { return }
                self.state.onConfirmRecord?(target)
            }

            let rootView = AreaSelectionScreenView(
                display: display,
                state: state
            )
            panel.contentView = NSHostingView(rootView: rootView)
            panel.setFrame(display.frame, display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
        }

        panels.first?.makeKey()
    }

    func dismiss() {
        for panel in panels {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        panels.removeAll()
    }

    private static func fallbackDisplaysFromNSScreens() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return DisplayInfo(
                id: CGDirectDisplayID(number.uint32Value),
                name: screen.localizedName,
                frame: screen.frame,
                scale: screen.backingScaleFactor
            )
        }
    }
}

// MARK: - SwiftUI Overlay Per Display

private struct AreaSelectionScreenView: View {
    let display: DisplayInfo
    @ObservedObject var state: AreaSelectionState

    private enum DragMode {
        case creating(startPoint: CGPoint)
        case moving(initialRect: CGRect, startPoint: CGPoint)
        case resizing(handle: ResizeHandle, initialRect: CGRect, startPoint: CGPoint)
    }

    enum ResizeHandle: CaseIterable {
        case topLeft, top, topRight
        case left, right
        case bottomLeft, bottom, bottomRight
    }

    @State private var dragMode: DragMode?

    private let minSelectionDimension: CGFloat = 32
    private let handleHitSize: CGFloat = 14

    private var selectionRectOnThisDisplay: CGRect? {
        guard let selection = state.activeSelection,
              selection.displayID == display.id else {
            return nil
        }
        return selection.rect
    }

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            ZStack(alignment: .topLeading) {
                dimmedBackdrop(in: bounds, cutout: selectionRectOnThisDisplay)
                    .contentShape(Rectangle())
                    .gesture(dragGesture(in: bounds))

                if let rect = selectionRectOnThisDisplay {
                    selectionChrome(rect: rect, in: bounds)
                } else {
                    instructionBanner
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func dimmedBackdrop(in bounds: CGRect, cutout: CGRect?) -> some View {
        Canvas { context, size in
            var fullPath = Path(CGRect(origin: .zero, size: size))
            if let cutout {
                fullPath.addRect(cutout)
            }
            context.fill(
                fullPath,
                with: .color(.black.opacity(0.45)),
                style: FillStyle(eoFill: true)
            )
        }
    }

    @ViewBuilder
    private func selectionChrome(rect: CGRect, in bounds: CGRect) -> some View {
        // Dashed selection border
        Rectangle()
            .strokeBorder(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .background(
                Rectangle()
                    .strokeBorder(Color.black.opacity(0.6), lineWidth: 0.5)
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)

        // Resize handles (4 corners + 4 edges)
        ForEach(ResizeHandle.allCases, id: \.self) { handle in
            let pt = handlePosition(for: handle, in: rect)
            Circle()
                .fill(Color.white)
                .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))
                .frame(width: 9, height: 9)
                .position(pt)
                .allowsHitTesting(false)
        }

        // Pixel dimensions + Record button bar
        controlsOverlay(for: rect, in: bounds)
    }

    @ViewBuilder
    private func controlsOverlay(for rect: CGRect, in bounds: CGRect) -> some View {
        let pixelWidth = max(2, Int((rect.width * display.scale).rounded()) & ~1)
        let pixelHeight = max(2, Int((rect.height * display.scale).rounded()) & ~1)

        let barY: CGFloat = {
            if rect.maxY + 48 <= bounds.height {
                return rect.maxY + 24
            } else if rect.minY - 48 >= 0 {
                return rect.minY - 24
            } else {
                return max(24, min(bounds.height - 24, rect.maxY - 24))
            }
        }()
        let barX = max(140, min(bounds.width - 140, rect.midX))

        HStack(spacing: 10) {
            Text("\(pixelWidth) × \(pixelHeight) px")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)

            Divider()
                .frame(height: 14)
                .overlay(Color.white.opacity(0.3))

            Button {
                if let target = state.currentCaptureTarget() {
                    state.onConfirmRecord?(target)
                }
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                    Text("Record")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.18)))
            }
            .buttonStyle(.plain)

            Button {
                state.onCancel?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(5)
            }
            .buttonStyle(.plain)
            .help("Cancel area selection (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.82))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
        )
        .position(x: barX, y: barY)
    }

    private var instructionBanner: some View {
        Text("Drag to select an area to record • Press Esc to cancel")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.75))
            )
    }

    // MARK: - Drag & Resize Interaction

    private func dragGesture(in bounds: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                let start = clampPoint(value.startLocation, in: bounds)
                let current = clampPoint(value.location, in: bounds)

                if dragMode == nil {
                    if let existing = selectionRectOnThisDisplay {
                        if let handle = hitTestHandle(at: start, in: existing) {
                            dragMode = .resizing(handle: handle, initialRect: existing, startPoint: start)
                        } else if existing.contains(start) {
                            dragMode = .moving(initialRect: existing, startPoint: start)
                        } else {
                            dragMode = .creating(startPoint: start)
                        }
                    } else {
                        dragMode = .creating(startPoint: start)
                    }
                }

                guard let mode = dragMode else { return }
                let updatedRect: CGRect
                switch mode {
                case .creating(let origin):
                    updatedRect = makeRect(from: origin, to: current, in: bounds)
                case .moving(let initialRect, let startPoint):
                    let dx = current.x - startPoint.x
                    let dy = current.y - startPoint.y
                    updatedRect = moveRect(initialRect, dx: dx, dy: dy, in: bounds)
                case .resizing(let handle, let initialRect, let startPoint):
                    let dx = current.x - startPoint.x
                    let dy = current.y - startPoint.y
                    updatedRect = resizeRect(initialRect, handle: handle, dx: dx, dy: dy, in: bounds)
                }

                state.activeSelection = AreaSelectionState.Selection(
                    displayID: display.id,
                    rect: updatedRect,
                    scale: display.scale
                )
            }
            .onEnded { _ in
                dragMode = nil
            }
    }

    private func clampPoint(_ point: CGPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: max(0, min(bounds.width, point.x)),
            y: max(0, min(bounds.height, point.y))
        )
    }

    private func makeRect(from p1: CGPoint, to p2: CGPoint, in bounds: CGRect) -> CGRect {
        let minX = min(p1.x, p2.x)
        let minY = min(p1.y, p2.y)
        let width = max(minSelectionDimension, abs(p2.x - p1.x))
        let height = max(minSelectionDimension, abs(p2.y - p1.y))
        let clampedX = max(0, min(bounds.width - width, minX))
        let clampedY = max(0, min(bounds.height - height, minY))
        return CGRect(
            x: round(clampedX),
            y: round(clampedY),
            width: round(min(width, bounds.width)),
            height: round(min(height, bounds.height))
        )
    }

    private func moveRect(_ rect: CGRect, dx: CGFloat, dy: CGFloat, in bounds: CGRect) -> CGRect {
        let newX = max(0, min(bounds.width - rect.width, rect.origin.x + dx))
        let newY = max(0, min(bounds.height - rect.height, rect.origin.y + dy))
        return CGRect(
            x: round(newX),
            y: round(newY),
            width: round(rect.width),
            height: round(rect.height)
        )
    }

    private func resizeRect(
        _ rect: CGRect,
        handle: ResizeHandle,
        dx: CGFloat,
        dy: CGFloat,
        in bounds: CGRect
    ) -> CGRect {
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        switch handle {
        case .topLeft:
            minX = min(maxX - minSelectionDimension, max(0, minX + dx))
            minY = min(maxY - minSelectionDimension, max(0, minY + dy))
        case .top:
            minY = min(maxY - minSelectionDimension, max(0, minY + dy))
        case .topRight:
            maxX = max(minX + minSelectionDimension, min(bounds.width, maxX + dx))
            minY = min(maxY - minSelectionDimension, max(0, minY + dy))
        case .left:
            minX = min(maxX - minSelectionDimension, max(0, minX + dx))
        case .right:
            maxX = max(minX + minSelectionDimension, min(bounds.width, maxX + dx))
        case .bottomLeft:
            minX = min(maxX - minSelectionDimension, max(0, minX + dx))
            maxY = max(minY + minSelectionDimension, min(bounds.height, maxY + dy))
        case .bottom:
            maxY = max(minY + minSelectionDimension, min(bounds.height, maxY + dy))
        case .bottomRight:
            maxX = max(minX + minSelectionDimension, min(bounds.width, maxX + dx))
            maxY = max(minY + minSelectionDimension, min(bounds.height, maxY + dy))
        }

        return CGRect(
            x: round(minX),
            y: round(minY),
            width: round(maxX - minX),
            height: round(maxY - minY)
        )
    }

    private func handlePosition(for handle: ResizeHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    private func hitTestHandle(at point: CGPoint, in rect: CGRect) -> ResizeHandle? {
        for handle in ResizeHandle.allCases {
            let pos = handlePosition(for: handle, in: rect)
            if hypot(point.x - pos.x, point.y - pos.y) <= handleHitSize {
                return handle
            }
        }
        return nil
    }
}
