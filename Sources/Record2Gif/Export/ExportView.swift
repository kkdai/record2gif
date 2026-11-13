import SwiftUI

struct ExportView: View {
    let videoURL: URL
    @EnvironmentObject private var model: AppModel

    init(videoURL: URL) {
        self.videoURL = videoURL
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Export GIF")
                .font(.headline)
            Text(videoURL.lastPathComponent)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Back") {
                model.phase = .idle
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 260)
    }
}
