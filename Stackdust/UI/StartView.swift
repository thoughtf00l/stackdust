import SwiftUI
import AppKit
import StackdustCore

struct StartView: View {
    let model: AppModel
    @State private var volumes: [VolumeInfo] = []

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "internaldrive")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Stackdust")
                .font(.largeTitle.bold())
            VStack(spacing: 4) {
                Text("Choose a folder to scan")
                    .foregroundStyle(.secondary)
                if model.reclaimedTotalBytes > 0 {
                    Text("\(byteString(model.reclaimedTotalBytes)) reclaimed so far")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

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
                                    Text(caption(for: volume))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.bordered)
                        .foregroundStyle(.primary)
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

    /// A volume row's second line: the mount path, plus a "· NN.N GB free of NNN.N GB" suffix
    /// when both capacities are known. Missing values drop the suffix and leave the path alone.
    private func caption(for volume: VolumeInfo) -> String {
        guard let free = volume.freeCapacity, let total = volume.totalCapacity else {
            return volume.url.path
        }
        return "\(volume.url.path) · \(byteString(free)) free of \(byteString(total))"
    }
}
