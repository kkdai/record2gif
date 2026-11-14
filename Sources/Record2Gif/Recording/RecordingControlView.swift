import AppKit
import Combine
import CoreGraphics
import Record2GifCore
import SwiftUI

struct RecordingControlView: View {
    enum CaptureMode: String, CaseIterable, Identifiable {
        case entireScreen = "Entire Screen"
        case selectedArea = "Selected Area"

        var id: String { rawValue }
    }

    @EnvironmentObject private var model: AppModel

    @State private var captureMode: CaptureMode = .entireScreen
    @State private var displays: [DisplayInfo] = []
    @State private var selectedDisplayID: CGDirectDisplayID = CGMainDisplayID()
    @State private var fps: Int = 30
    @State private var showsCursor: Bool = true

    @State private var showPermissionSheet: Bool = false
    @State private var errorAlertMessage: String?
    @State private var isStartingOrStopping: Bool = false

    @State private var controlWindow: NSWindow?
    @State private var didInitialPositionWindow: Bool = false
    @State private var didDisableAutomaticTermination: Bool = false
    @State private var elapsedCancellable: AnyCancellable?

    @State private var overlayController = AreaSelectionOverlayController()
    @State private var hotKeyMonitor = GlobalHotKeyMonitor()

    private let availableFPSOptions = [15, 30, 60]

    var body: some View {
        HStack(spacing: 14) {
            closeButton

            Divider()
                .frame(height: 26)

            modeSelector

            Divider()
                .frame(height: 26)

            optionsMenu

            Divider()
                .frame(height: 26)

            recordButton

            if model.phase == .selectingArea {
                cancelAreaShortcutButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.28), radius: 12, x: 0, y: 4)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                )
        )
        .padding(8)
        .fixedSize()
        .background(
            ControlBarWindowAccessor { window in
                configureControlWindowIfNeeded(window)
            }
        )
        .sheet(isPresented: $showPermissionSheet) {
            PermissionGateSheet(
                onRequestAndOpenSettings: {
                    _ = ScreenRecorder.requestPermission()
                    if let url = URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                    ) {
                        NSWorkspace.shared.open(url)
                    }
                    if ScreenRecorder.hasPermission() {
                        showPermissionSheet = false
                        Task { await refreshDisplays() }
                    }
                },
                onDismiss: {
                    showPermissionSheet = false
                    if ScreenRecorder.hasPermission() {
                        Task { await refreshDisplays() }
                    }
                }
            )
        }
        .alert(
            "Recording Error",
            isPresented: Binding(
                get: { errorAlertMessage != nil },
                set: { if !$0 { errorAlertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                errorAlertMessage = nil
            }
        } message: {
            Text(errorAlertMessage ?? "")
        }
        .onAppear {
            wireAppModelCallbacks()
            handleOnAppear()
        }
        .onChange(of: model.phase) { _, newPhase in
            handlePhaseChange(newPhase)
        }
    }

    // MARK: - Control Bar Subviews

    private var closeButton: some View {
        Button {
            if model.phase == .selectingArea {
                cancelAreaSelection()
            } else {
                overlayController.dismiss()
                controlWindow?.orderOut(nil)
            }
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(model.phase == .selectingArea ? "Cancel Area Selection (Esc)" : "Close Control Bar")
    }

    private var modeSelector: some View {
        HStack(spacing: 6) {
            modeButton(
                mode: .entireScreen,
                systemImage: "macwindow",
                title: "Entire Screen"
            )
            modeButton(
                mode: .selectedArea,
                systemImage: "viewfinder",
                title: "Selected Area"
            )
        }
    }

    private func modeButton(mode: CaptureMode, systemImage: String, title: String) -> some View {
        let isSelected = captureMode == mode
        return Button {
            selectCaptureMode(mode)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var optionsMenu: some View {
        Menu {
            if displays.count > 1 {
                Section("Display") {
                    Picker("Display", selection: $selectedDisplayID) {
                        ForEach(displays) { display in
                            Text(display.name).tag(display.id)
                        }
                    }
                }
            }

            Section("Frame Rate") {
                Picker("Frame Rate", selection: $fps) {
                    ForEach(availableFPSOptions, id: \.self) { rate in
                        Text("\(rate) fps").tag(rate)
                    }
                }
            }

            Section("Pointer") {
                Toggle("Show Mouse Cursor", isOn: $showsCursor)
            }
        } label: {
            HStack(spacing: 4) {
                Text("Options")
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var recordButton: some View {
        Button {
            triggerRecordAction()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.45), lineWidth: 1)
                    )
                Text("Record")
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.red.opacity(0.16))
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .disabled(isStartingOrStopping || model.phase == .recording)
    }

    private var cancelAreaShortcutButton: some View {
        Button("") {
            cancelAreaSelection()
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .keyboardShortcut(.cancelAction)
    }

    // MARK: - Actions & Phase Transitions

    private func handleOnAppear() {
        populateFallbackDisplaysFromNSScreens()
        if !ScreenRecorder.hasPermission() {
            showPermissionSheet = true
        } else {
            Task {
                await refreshDisplays()
            }
        }
    }

    private func wireAppModelCallbacks() {
        model.onStopRecordingRequested = {
            Task { @MainActor in
                await stopRecording()
            }
        }
        model.onNewRecordingRequested = {
            Task { @MainActor in
                overlayController.dismiss()
                captureMode = .entireScreen
                if let window = controlWindow {
                    applyControlBarStyle(to: window, aboveOverlay: false)
                    positionControlBarNearBottom(window)
                    window.makeKeyAndOrderFront(nil)
                }
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func handlePhaseChange(_ newPhase: AppModel.Phase) {
        switch newPhase {
        case .idle:
            overlayController.dismiss()
            if captureMode == .selectedArea {
                captureMode = .entireScreen
            }
            if let window = controlWindow {
                applyControlBarStyle(to: window, aboveOverlay: false)
                positionControlBarNearBottom(window)
                window.makeKeyAndOrderFront(nil)
            }
        case .selectingArea:
            if let window = controlWindow {
                applyControlBarStyle(to: window, aboveOverlay: true)
            }
            presentAreaOverlay()
        case .recording:
            overlayController.dismiss()
            controlWindow?.orderOut(nil)
        case .exporting:
            overlayController.dismiss()
            if let window = controlWindow {
                restoreStandardWindowStyle(to: window)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func selectCaptureMode(_ mode: CaptureMode) {
        captureMode = mode
        switch mode {
        case .entireScreen:
            overlayController.dismiss()
            if model.phase == .selectingArea {
                model.phase = .idle
            }
        case .selectedArea:
            guard ensurePermissionOrShowGate() else {
                captureMode = .entireScreen
                return
            }
            model.phase = .selectingArea
        }
    }

    private func presentAreaOverlay() {
        overlayController.present(
            displays: displays,
            preferredDisplayID: selectedDisplayID,
            onConfirmRecord: { target in
                Task { @MainActor in
                    await startRecording(target: target)
                }
            },
            onCancel: {
                Task { @MainActor in
                    cancelAreaSelection()
                }
            }
        )
    }

    private func cancelAreaSelection() {
        overlayController.dismiss()
        captureMode = .entireScreen
        model.phase = .idle
        if let window = controlWindow {
            applyControlBarStyle(to: window, aboveOverlay: false)
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func triggerRecordAction() {
        guard ensurePermissionOrShowGate() else { return }

        switch captureMode {
        case .entireScreen:
            let displayID = resolvedTargetDisplayID()
            Task { @MainActor in
                await startRecording(target: .display(displayID))
            }
        case .selectedArea:
            if model.phase != .selectingArea {
                model.phase = .selectingArea
            }
            if let target = overlayController.state.currentCaptureTarget() {
                Task { @MainActor in
                    await startRecording(target: target)
                }
            }
        }
    }

    private func ensurePermissionOrShowGate() -> Bool {
        if ScreenRecorder.hasPermission() {
            return true
        }
        showPermissionSheet = true
        return false
    }

    private func refreshDisplays() async {
        guard ScreenRecorder.hasPermission() else { return }
        do {
            let fetched = try await model.recorder.availableDisplays()
            if !fetched.isEmpty {
                displays = fetched
                if !fetched.contains(where: { $0.id == selectedDisplayID }),
                   let first = fetched.first {
                    selectedDisplayID = first.id
                }
            }
        } catch {
            populateFallbackDisplaysFromNSScreens()
        }
    }

    private func populateFallbackDisplaysFromNSScreens() {
        let mapped: [DisplayInfo] = NSScreen.screens.compactMap { screen in
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
        if !mapped.isEmpty {
            displays = mapped
            if !mapped.contains(where: { $0.id == selectedDisplayID }),
               let first = mapped.first {
                selectedDisplayID = first.id
            }
        }
    }

    private func resolvedTargetDisplayID() -> CGDirectDisplayID {
        if displays.contains(where: { $0.id == selectedDisplayID }) {
            return selectedDisplayID
        }
        return displays.first?.id ?? CGMainDisplayID()
    }

    // MARK: - Start & Stop Recording

    private func startRecording(target: CaptureTarget) async {
        guard !isStartingOrStopping, !model.recorder.isRecording else { return }
        guard ensurePermissionOrShowGate() else { return }

        isStartingOrStopping = true
        defer { isStartingOrStopping = false }

        var excludedIDs = overlayController.overlayWindowIDs
        if let window = controlWindow, window.windowNumber > 0 {
            excludedIDs.append(CGWindowID(window.windowNumber))
        }

        if !didDisableAutomaticTermination {
            ProcessInfo.processInfo.disableAutomaticTermination("Recording")
            didDisableAutomaticTermination = true
        }

        overlayController.dismiss()
        controlWindow?.orderOut(nil)
        model.phase = .recording

        let options = RecordingOptions(
            target: target,
            fps: fps,
            showsCursor: showsCursor,
            excludedWindowIDs: Array(Set(excludedIDs))
        )

        model.statusItemController?.showRecording(elapsed: 0)
        elapsedCancellable = model.recorder.$elapsed
            .receive(on: RunLoop.main)
            .sink { [weak model] elapsed in
                model?.statusItemController?.showRecording(elapsed: elapsed)
            }

        hotKeyMonitor.register {
            Task { @MainActor in
                await stopRecording()
            }
        }

        do {
            try await model.recorder.start(options)
        } catch {
            cleanupAfterRecordingEnds()
            model.phase = .idle
            if let window = controlWindow {
                applyControlBarStyle(to: window, aboveOverlay: false)
                window.makeKeyAndOrderFront(nil)
            }
            presentError(error)
        }
    }

    private func stopRecording() async {
        guard !isStartingOrStopping, model.recorder.isRecording else { return }
        isStartingOrStopping = true
        defer { isStartingOrStopping = false }

        cleanupAfterRecordingEnds()

        do {
            let outputURL = try await model.recorder.stop()
            if let window = controlWindow {
                restoreStandardWindowStyle(to: window)
                window.makeKeyAndOrderFront(nil)
            }
            model.phase = .exporting(outputURL)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            model.phase = .idle
            if let window = controlWindow {
                applyControlBarStyle(to: window, aboveOverlay: false)
                window.makeKeyAndOrderFront(nil)
            }
            presentError(error)
        }
    }

    private func cleanupAfterRecordingEnds() {
        hotKeyMonitor.unregister()
        elapsedCancellable?.cancel()
        elapsedCancellable = nil
        model.statusItemController?.showIdle()
        if didDisableAutomaticTermination {
            ProcessInfo.processInfo.enableAutomaticTermination("Recording")
            didDisableAutomaticTermination = false
        }
    }

    private func presentError(_ error: Error) {
        if let recorderError = error as? RecorderError {
            switch recorderError {
            case .permissionDenied:
                showPermissionSheet = true
            case .displayNotFound:
                errorAlertMessage = "The selected display could not be found."
            case .alreadyRecording:
                errorAlertMessage = "A screen recording is already in progress."
            case .notRecording:
                errorAlertMessage = "No active recording to stop."
            case .writerFailed(let reason):
                errorAlertMessage = "Screen recording failed: \(reason)"
            }
        } else {
            errorAlertMessage = error.localizedDescription
        }
    }

    // MARK: - Window Styling

    private func configureControlWindowIfNeeded(_ window: NSWindow) {
        if controlWindow !== window {
            controlWindow = window
        }
        window.isReleasedWhenClosed = false
        if case .exporting = model.phase { return }
        let aboveOverlay = (model.phase == .selectingArea)
        applyControlBarStyle(to: window, aboveOverlay: aboveOverlay)

        if !didInitialPositionWindow {
            didInitialPositionWindow = true
            positionControlBarNearBottom(window)
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                if case .exporting = model.phase { return }
                sizeWindowToFitContent(window)
                positionControlBarNearBottom(window)
            }
        }
    }

    private func sizeWindowToFitContent(_ window: NSWindow) {
        guard let contentView = window.contentView else { return }
        contentView.layoutSubtreeIfNeeded()
        let fitting = contentView.fittingSize
        if fitting.width > 0 && fitting.height > 0 {
            window.setContentSize(fitting)
        }
    }

    private func applyControlBarStyle(to window: NSWindow, aboveOverlay: Bool) {
        window.level = aboveOverlay
            ? NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            : .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        sizeWindowToFitContent(window)
    }

    private func restoreStandardWindowStyle(to window: NSWindow) {
        window.level = .normal
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.hasShadow = true
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.managed, .participatesInCycle]
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
        window.center()
    }

    private func positionControlBarNearBottom(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visibleFrame = screen.visibleFrame
        let size = window.frame.size
        let originX = round(visibleFrame.midX - size.width / 2.0)
        let originY = round(visibleFrame.minY + 48.0)
        window.setFrameOrigin( CGPoint(x: originX, y: originY))
    }
}

// MARK: - Permission Gate Sheet

private struct PermissionGateSheet: View {
    let onRequestAndOpenSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.system(size: 40))
                .foregroundStyle(.red)

            Text("Screen Recording Permission Required")
                .font(.headline)

            Text(
                "record2gif needs Screen Recording permission to capture your screen and export it as an animated GIF. Click below to grant access in System Settings → Privacy & Security → Screen Recording."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Later") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Open System Settings") {
                    onRequestAndOpenSettings()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 420)
    }
}

// MARK: - Hosting Window Accessor

private struct ControlBarWindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowObserverView()
        view.onWindowChange = onResolve
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            onResolve(window)
        }
    }

    private final class WindowObserverView: NSView {
        var onWindowChange: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                onWindowChange?(window)
            }
        }
    }
}
