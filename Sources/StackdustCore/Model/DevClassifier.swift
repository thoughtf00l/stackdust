import Foundation

/// Classifies a scanned `FileNode` tree against a `DevItemCatalog`, marking the roots of
/// developer-reclaimable items and aggregating their sizes.
///
/// Like `TreeEditor`, this is a pure walk over the in-memory tree: it mutates only the
/// tree's own `devCategory`/`devSize` fields and never touches the disk, so it is safe to
/// run off the main thread on an otherwise-untouched tree (the same model as
/// `AppModel.recountUnreadable`).
public enum DevClassifier {

    /// Walks `root` once, setting `devCategory` on the outermost node that matches a rule and
    /// filling in `devSize` for every node.
    ///
    /// The outermost match wins: when a node matches, the whole subtree is a dev item, so its
    /// `devSize` is set to `allocatedSize` and the walk does not descend further (descendants
    /// keep `devCategory == nil`). For a non-matching directory `devSize` is the sum of its
    /// children's `devSize`; for a non-matching file it is 0.
    public static func classify(_ root: FileNode, using catalog: DevItemCatalog) {
        // Track the absolute path incrementally instead of calling `FileNode.path` per node,
        // which rebuilds the string from the parent chain (O(depth) each) — far too slow on
        // trees with millions of nodes. `root.name` is the scan root's absolute path.
        walk(root, path: root.name, catalog: catalog)
    }

    @discardableResult
    private static func walk(_ node: FileNode, path: String, catalog: DevItemCatalog) -> Int64 {
        if let category = catalog.category(for: node, path: path) {
            node.devCategory = category
            node.devSize = node.allocatedSize
            return node.devSize
        }

        node.devCategory = nil
        guard let children = node.children else {
            node.devSize = 0
            return 0
        }

        var total: Int64 = 0
        for child in children {
            let childPath = path.hasSuffix("/") ? path + child.name : path + "/" + child.name
            total += walk(child, path: childPath, catalog: catalog)
        }
        node.devSize = total
        return total
    }

    /// Whether `node` is a dev item or lives inside one, found by walking the parent chain for a
    /// non-nil `devCategory`. O(depth); intended for occasional per-node queries (panel rows,
    /// trash gating), not a per-frame walk of the whole tree.
    public static func isWithinDevItem(_ node: FileNode) -> Bool {
        var current: FileNode? = node
        while let candidate = current {
            if candidate.devCategory != nil { return true }
            current = candidate.parent
        }
        return false
    }
}
