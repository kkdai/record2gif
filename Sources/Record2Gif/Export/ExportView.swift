import AppKit
import AVFoundation
import Record2GifCore
import SwiftUI
import UniformTypeIdentifiers

struct ExportView: View {
    let videoURL: URL
    @EnvironmentObject private var model: AppModel

    @AppStorage("export.resolution") private var storedResolutionRaw: String = ResolutionChoice.w960.rawValue
    @AppStorage("export.customWidth") private var storedCustomWidth: Int = 640
    @AppStorage("export.fps") private var storedFPS: Int = 15
    @AppStorage("export.loopForever") private var loopForever: Bool = true

    @State private var sourceSize: CGSize = CGSize(width: 1280, height: 720)
    @State private var duration: TimeInterval = 1.0
    @State private var isMetadataLoaded: Bool = false

    @State private var customWidthText: String = "640"
    @State private var isExporting: Bool = false
    @State private var exportProgress: Double = 0.0
    @State private var exportTask: Task<Void, Never>?
    @State private var exportedGIFURL: URL?
    @State private var errorMessage: String?
    @State private var showDiscardConfirmation: Bool = false
    @State private var didCleanUpTempVideo: Bool = false

    init(videoURL: URL) {
        self.videoURL = videoURL
    }

    private var selectedChoice: ResolutionChoice {
        ResolutionChoice(rawValue: storedResolutionRaw) ?? .w960
    }

    private var selectedChoiceBinding: Binding<ResolutionChoice> {
        Binding(
            get: { ResolutionChoice(rawValue: storedResolutionRaw) ?? .w960 },
            set: { newValue in
                storedResolutionRaw = newValue.rawValue
            }
        )
    }

    private var selectedFPSBinding: Binding<Int> {
        Binding(
            get: { ExportHelpers.sanitizeFPS(storedFPS) },
            set: { newValue in
                storedFPS = ExportHelpers.sanitizeFPS(newValue)
            }
        )
    }

    private var sourceWidthInt: Int {
        max(ExportHelpers.minCustomWidth, Int(sourceSize.width.rounded()))
    }

    private var effectiveCustomWidth: Int {
        ExportHelpers.parseCustomWidth(
            customWidthText,
            fallback: storedCustomWidth,
            sourceWidth: sourceWidthInt
        )
    }

    private var activeResolution: GIFResolution {
        selectedChoice.toGIFResolution(customWidth: effectiveCustomWidth)
    }

    private var activeFPS: Int {
        ExportHelpers.sanitizeFPS(storedFPS)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            previewSection
            controlsSection
            statusSection
            footerActions
        }
        .padding(20)
        .frame(minWidth: 540, idealWidth: 600, minHeight: 480)
        .task(id: videoURL) {
            syncCustomWidthField()
            await loadVideoMetadata(for: videoURL)
        }
        .onDisappear {
            finishAndReturnIdle()
        }
        .confirmationDialog(
            "Discard this recording?",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Recording", role: .destructive) {
                finishAndReturnIdle()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The temporary screen recording will be permanently deleted.")
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            LoopingVideoPreview(videoURL: videoURL)
                .frame(minHeight: 240, maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )

            HStack {
                Label(
                    isMetadataLoaded
                        ? ExportHelpers.formattedSourceSummary(source: sourceSize, duration: duration)
                        : "Loading video metadata…",
                    systemImage: "film"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                Text(
                    ExportHelpers.formattedOutputSummary(
                        source: sourceSize,
                        duration: duration,
                        resolution: activeResolution,
                        fps: activeFPS
                    )
                )
                .font(.caption.monospacedDigit())
                .fontWeight(.medium)
                .foregroundStyle(.primary)
            }
        }
    }

    private var controlsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Picker("Resolution", selection: selectedChoiceBinding) {
                        ForEach(ResolutionChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 240)

                    if selectedChoice == .custom {
                        HStack(spacing: 6) {
                            TextField("Width", text: $customWidthText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 76)
                                .onSubmit {
                                    commitCustomWidth()
                                }
                                .onChange(of: customWidthText) { _, newValue in
                                    let filtered = newValue.filter(\.isNumber)
                                    if filtered != newValue {
                                        customWidthText = filtered
                                    }
                                    if let value = Int(filtered) {
                                        storedCustomWidth = ExportHelpers.clampCustomWidth(
                                            value,
                                            sourceWidth: sourceWidthInt
                                        )
                                    }
                                }
                            Text("px (16–\(sourceWidthInt))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()
                }

                HStack(spacing: 20) {
                    Picker("Frame rate", selection: selectedFPSBinding) {
                        ForEach(ExportHelpers.availableFPS, id: \.self) { fps in
                            Text("\(fps) fps").tag(fps)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)

                    Toggle("Loop forever", isOn: $loopForever)
                        .toggleStyle(.checkbox)

                    Spacer()
                }
            }
            .padding(8)
        }
        .disabled(isExporting)
    }

    @ViewBuilder
    private var statusSection: some View {
        if isExporting {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ProgressView(value: exportProgress, total: 1.0)
                        .progressViewStyle(.linear)
                    Text("\(Int((exportProgress * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    Button("Cancel") {
                        exportTask?.cancel()
                    }
                }
                Text("Encoding animated GIF…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let savedURL = exportedGIFURL {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Saved \(savedURL.lastPathComponent)")
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([savedURL])
                }
                Button("New Recording") {
                    finishAndReturnIdle()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(10)
            .background(Color.green.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if let errorMessage {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var footerActions: some View {
        HStack {
            Button(role: .destructive) {
                showDiscardConfirmation = true
            } label: {
                Text("Discard")
            }
            .disabled(isExporting)

            Spacer()

            Button("Save GIF…") {
                presentSavePanelAndExport()
            }
            .buttonStyle(.borderedProminent)
            .disabled(isExporting || !isMetadataLoaded)
        }
    }

    private func syncCustomWidthField() {
        let clamped = ExportHelpers.clampCustomWidth(storedCustomWidth, sourceWidth: sourceWidthInt)
        storedCustomWidth = clamped
        customWidthText = String(clamped)
        storedFPS = ExportHelpers.sanitizeFPS(storedFPS)
    }

    private func commitCustomWidth() {
        let validated = ExportHelpers.parseCustomWidth(
            customWidthText,
            fallback: storedCustomWidth,
            sourceWidth: sourceWidthInt
        )
        storedCustomWidth = validated
        customWidthText = String(validated)
    }

    private func loadVideoMetadata(for url: URL) async {
        let asset = AVURLAsset(url: url)
        do {
            let (tracks, loadedDuration) = try await asset.load(.tracks, .duration)
            guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
                errorMessage = "No video track found in recording."
                return
            }
            let (naturalSize, preferredTransform) = try await videoTrack.load(
                .naturalSize,
                .preferredTransform
            )
            let transformed = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
            let size = CGSize(width: abs(transformed.width), height: abs(transformed.height))
            let seconds = max(0, CMTimeGetSeconds(loadedDuration))

            sourceSize = size.width > 0 && size.height > 0 ? size : CGSize(width: 1280, height: 720)
            duration = seconds.isFinite && seconds > 0 ? seconds : 0.1
            isMetadataLoaded = true
            syncCustomWidthField()
        } catch {
            if !Task.isCancelled {
                errorMessage = "Failed to load recording metadata."
            }
        }
    }

    private func presentSavePanelAndExport() {
        commitCustomWidth()
        errorMessage = nil

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = ExportHelpers.defaultFileName()

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        let options = GIFExportOptions(
            resolution: activeResolution,
            fps: activeFPS,
            loopForever: loopForever
        )
        startExport(to: destinationURL, options: options)
    }

    private func startExport(to destinationURL: URL, options: GIFExportOptions) {
        exportTask?.cancel()
        exportedGIFURL = nil
        errorMessage = nil
        exportProgress = 0.0
        isExporting = true

        let sourceURL = videoURL
        let exporter = GIFExporter()

        exportTask = Task {
            do {
                try await exporter.export(
                    video: sourceURL,
                    to: destinationURL,
                    options: options,
                    progress: { value in
                        Task { @MainActor in
                            self.exportProgress = min(max(value, 0.0), 1.0)
                        }
                    }
                )
                await MainActor.run {
                    self.isExporting = false
                    self.exportProgress = 1.0
                    self.exportedGIFURL = destinationURL
                    self.exportTask = nil
                }
            } catch GIFExportError.cancelled {
                await MainActor.run {
                    self.isExporting = false
                    self.exportProgress = 0.0
                    self.exportTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isExporting = false
                    self.exportProgress = 0.0
                    self.exportTask = nil
                }
            } catch {
                await MainActor.run {
                    self.isExporting = false
                    self.exportProgress = 0.0
                    self.errorMessage = "GIF export failed: \(error.localizedDescription)"
                    self.exportTask = nil
                }
            }
        }
    }

    private func finishAndReturnIdle() {
        exportTask?.cancel()
        exportTask = nil

        if !didCleanUpTempVideo {
            didCleanUpTempVideo = true
            try? FileManager.default.removeItem(at: videoURL)
        }

        if model.phase == .exporting(videoURL) {
            model.phase = .idle
        }
    }
}
