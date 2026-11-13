import SwiftUI

struct RecordingControlView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "record.circle")
                .font(.system(size: 36))
                .foregroundStyle(.red)
            Text("record2gif")
                .font(.headline)
            Text("Ready to record")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minWidth: 320, minHeight: 160)
    }
}
