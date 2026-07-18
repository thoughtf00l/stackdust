import Foundation
import StackdustCore

/// Human-readable "size on disk" string.
func byteString(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

extension FileNode {
    /// Display label: the last path component for the scan root (whose `name` is an
    /// absolute path), otherwise the entry name.
    var displayName: String {
        guard parent == nil else { return name }
        let last = (name as NSString).lastPathComponent
        return last.isEmpty ? name : last
    }
}

// Reference identity is stable for the lifetime of a scan, which is all SwiftUI's
// ForEach/List need. Declared in the UI layer; the ScanEngine sources are untouched.
extension FileNode: @retroactive Identifiable {
    public var id: ObjectIdentifier { ObjectIdentifier(self) }
}
