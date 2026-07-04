import Foundation

/// A node in the scanned file tree.
///
/// Designed for trees with millions of nodes, so it is deliberately lean:
/// - a `final class` (identity + shared references, no value-copy overhead per subtree),
/// - no `URL` stored per node; absolute paths are reconstructed from the parent chain,
/// - no `Codable`/reflection machinery.
///
/// Thread-safety: during a scan each node is mutated only by the single worker that
/// enumerated its parent directory (which appends this node) or, for directories, by the
/// single worker that enumerates this node (which fills `children`/`isUnreadable`).
/// Ownership is handed between workers through a lock that establishes happens-before,
/// and the final size aggregation runs after all workers have finished. Hence the
/// `@unchecked Sendable` conformance: there is no concurrent mutation of the same node.
final class FileNode: @unchecked Sendable {
    /// For the root node this holds the absolute path of the scan root (e.g. "/Applications"
    /// or "/"); for every other node it is just the entry's own name. `path` relies on this.
    let name: String

    let isDirectory: Bool

    /// Physical "size on disk" in bytes.
    /// For files: the file's own allocated size (0 for hard-link occurrences already counted).
    /// For directories: the aggregated total of all descendants (files only, no directory
    /// metadata overhead), filled in during the post-order aggregation pass.
    var allocatedSize: Int64

    /// `nil` for non-directories; an array (possibly empty) for directories.
    var children: [FileNode]?

    /// Set when the directory could not be opened/read (e.g. permission denied), or for a
    /// directory entry the file system reported a per-entry error for. The scan continues.
    var isUnreadable: Bool

    /// Weak to avoid retain cycles (children are owned strongly by their parent).
    weak var parent: FileNode?

    init(name: String, isDirectory: Bool, allocatedSize: Int64 = 0, parent: FileNode?) {
        self.name = name
        self.isDirectory = isDirectory
        self.allocatedSize = allocatedSize
        self.children = isDirectory ? [] : nil
        self.isUnreadable = false
        self.parent = parent
    }

    /// Reconstructs the absolute path by walking the parent chain up to the root.
    var path: String {
        var components: [String] = []
        var node: FileNode? = self
        while let current = node {
            components.append(current.name)
            node = current.parent
        }
        components.reverse()

        // First component is the root's absolute path; the rest are plain names.
        guard var result = components.first else { return "" }
        for component in components.dropFirst() {
            if result.hasSuffix("/") {
                result += component
            } else {
                result += "/" + component
            }
        }
        return result
    }
}
