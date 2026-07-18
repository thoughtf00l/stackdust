import Foundation

/// A node in the scanned file tree.
///
/// Designed for trees with millions of nodes, so it is deliberately lean:
/// - a `final class` (identity + shared references, no value-copy overhead per subtree),
/// - no `URL` stored per node; absolute paths are reconstructed from the parent chain,
/// - no `Codable`/reflection machinery.
///
/// The developer-classification fields (`devSize`, `devCategory`) default to empty and are
/// populated only by an optional `DevClassifier` pass after a scan; a tree that is never
/// classified leaves them at their defaults.
///
/// Thread-safety: during a scan the coordinator publishes a directory's `children` exactly
/// once, with a single assignment made under its tree lock when enumeration of that directory
/// finishes; the same lock guards bubbling each directory's direct-file bytes up the `parent`
/// chain into every ancestor's `allocatedSize` (giving directories monotonically growing partial
/// sums), and setting `isUnreadable`/`isCloudEvicted` on a node already visible to snapshot
/// readers. Any reader
/// that walks a live tree — the partial-snapshot copy — takes the same lock, which establishes
/// happens-before for the published `children`/sizes. The final size aggregation runs after all
/// workers have finished, under the same lock. A node's own `name`/`isDirectory` are immutable,
/// and a leaf's `allocatedSize` is set at init before the node is published. Hence the
/// `@unchecked Sendable` conformance: there is no unsynchronized concurrent access to a node.
public final class FileNode: @unchecked Sendable {
    /// For the root node this holds the absolute path of the scan root (e.g. "/Applications"
    /// or "/"); for every other node it is just the entry's own name. `path` relies on this.
    public let name: String

    public let isDirectory: Bool

    /// Physical "size on disk" in bytes.
    /// For files: the file's own allocated size (0 for hard-link occurrences already counted).
    /// For directories: the aggregated total of all descendants (files only, no directory
    /// metadata overhead), filled in during the post-order aggregation pass.
    public internal(set) var allocatedSize: Int64

    /// `nil` for non-directories; an array (possibly empty) for directories.
    public internal(set) var children: [FileNode]?

    /// Set when the directory could not be opened/read (e.g. permission denied), or for a
    /// directory entry the file system reported a per-entry error for. The scan continues.
    /// Mutually exclusive with `isCloudEvicted`: a node carries at most one of the two.
    public internal(set) var isUnreadable: Bool

    /// Set when a directory was skipped because its content is evicted to iCloud (dataless):
    /// it occupies ~no local disk space and was intentionally not downloaded (opening it would
    /// force fileproviderd to materialize the whole package). Mutually exclusive with
    /// `isUnreadable`, which is reserved for genuine read failures.
    public internal(set) var isCloudEvicted: Bool = false

    /// Bytes within this subtree attributable to developer-reclaimable items, filled in by a
    /// `DevClassifier` pass. Equals `allocatedSize` on a dev-item root; on a plain directory it
    /// is the sum of its children's `devSize`; on a plain file it is 0.
    public internal(set) var devSize: Int64 = 0

    /// Non-nil only on the outermost node that matched a `DevItemCatalog` rule (a dev-item root);
    /// descendants of a matched node are left `nil`. Set by a `DevClassifier` pass.
    public internal(set) var devCategory: DevCategory?

    /// Weak to avoid retain cycles (children are owned strongly by their parent).
    public internal(set) weak var parent: FileNode?

    init(name: String, isDirectory: Bool, allocatedSize: Int64 = 0, parent: FileNode?) {
        self.name = name
        self.isDirectory = isDirectory
        self.allocatedSize = allocatedSize
        self.children = isDirectory ? [] : nil
        self.isUnreadable = false
        self.parent = parent
    }

    /// Reconstructs the absolute path by walking the parent chain up to the root.
    public var path: String {
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
