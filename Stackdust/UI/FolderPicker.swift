import AppKit

/// A mounted volume offered as a quick-start scan target.
struct VolumeInfo: Identifiable {
    let url: URL
    let name: String
    let isInternal: Bool
    /// Total volume size in bytes; nil when the resource value is unavailable.
    let totalCapacity: Int64?
    /// Free space in bytes, including purgeable space (the figure Finder reports); nil when
    /// unavailable.
    let freeCapacity: Int64?
    var id: URL { url }
}

/// Directory selection (NSOpenPanel) and mounted-volume discovery. Must be used on the
/// main thread.
enum FolderPicker {
    static func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to scan"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func mountedVolumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeIsBrowsableKey, .volumeIsInternalKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]
        let manager = FileManager.default
        guard let urls = manager.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]
        ) else { return [] }

        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.volumeIsBrowsable ?? false else { return nil }
            return VolumeInfo(
                url: url,
                name: values?.volumeName ?? url.lastPathComponent,
                isInternal: values?.volumeIsInternal ?? true,
                totalCapacity: values?.volumeTotalCapacity.map(Int64.init),
                freeCapacity: values?.volumeAvailableCapacityForImportantUsage
            )
        }
    }
}
