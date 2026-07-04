import SwiftUI
import AppKit

struct StartView: View {
    let model: AppModel
    @State private var volumes: [VolumeInfo] = []

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "internaldrive")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("DiscFree")
                .font(.largeTitle.bold())
            Text("Choose a folder to scan")
                .foregroundStyle(.secondary)

            Button(action: chooseFolder) {
                Label("Choose Folder…", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if model.isFullDiskAccessMissing {
                FullDiskAccessBanner(
                    onOpenSettings: { FullDiskAccessCheck.openSystemSettings() },
                    onRecheck: { model.refreshFullDiskAccess() }
                )
                .padding(.top, 4)
            }

            if !volumes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Volumes")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    ForEach(volumes) { volume in
                        Button {
                            model.startScan(at: volume.url)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: volume.isInternal ? "internaldrive" : "externaldrive")
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(volume.name)
                                    Text(volume.url.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: 420)
                .padding(.top, 8)
            }

            Spacer()
        }
        .padding(40)
        .task { volumes = FolderPicker.mountedVolumes() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshFullDiskAccess()
        }
    }

    private func chooseFolder() {
        if let url = FolderPicker.chooseDirectory() {
            model.startScan(at: url)
        }
    }
}
