import SwiftUI
import StackdustCore

struct ScanningView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            ProgressView()
                .controlSize(.large)
            Text("Scanning…")
                .font(.title2.bold())

            VStack(spacing: 6) {
                Text(byteString(model.progress.bytesAccumulated))
                    .font(.title3)
                    .monospacedDigit()
                Text("\(model.progress.itemsScanned.formatted()) items")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(model.progress.currentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 460)
            }

            Button(role: .cancel) {
                model.returnToStart()
            } label: {
                Text("Cancel")
            }
            .keyboardShortcut(.cancelAction)
            .padding(.top, 4)

            Spacer()
        }
        .padding(40)
    }
}
