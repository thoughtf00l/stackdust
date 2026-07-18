import Foundation

/// One developer-reclaimable item: the dev-item root node, its absolute path, and the bytes it
/// occupies. `bytes` is captured from `node.allocatedSize` when the summary is built so the value
/// stays stable for display even if the underlying tree mutates later (e.g. after a trash).
public struct ReclaimItem: Sendable {
    public let node: FileNode
    public let path: String
    public let bytes: Int64
}

/// All reclaimable items of one `DevCategory`, with their combined size.
public struct ReclaimGroup: Sendable {
    public let category: DevCategory
    public let items: [ReclaimItem]
    public let totalBytes: Int64
}

/// Aggregates a classified `FileNode` tree into category-first `ReclaimGroup`s, the data behind a
/// category-first "Reclaim" view (as opposed to navigating the file tree).
///
/// Like `DevClassifier`, this is a pure walk over the in-memory tree: no disk access and no
/// mutation, so it is safe to run off the main thread. It expects a quiescent, already-classified
/// tree (`DevClassifier.classify` has run; the outermost matches carry a non-nil `devCategory`) —
/// the same model as `DevClassifier` itself.
public enum ReclaimSummary {

    /// Walks `root` once and returns the reclaimable items grouped by category. Items within a
    /// group are sorted by `bytes` descending; groups are sorted by `totalBytes` descending. On an
    /// unclassified tree (or a classified tree with no matches) this returns `[]`.
    public static func build(from root: FileNode) -> [ReclaimGroup] {
        var itemsByCategory: [DevCategory: [ReclaimItem]] = [:]
        // Track the absolute path incrementally instead of calling `FileNode.path` per node (an
        // O(depth) string rebuild — far too slow on trees with millions of nodes), exactly as
        // `DevClassifier.walk` does. `root.name` is the scan root's absolute path.
        walk(root, path: root.name, into: &itemsByCategory)

        let groups = itemsByCategory.map { category, items -> ReclaimGroup in
            let sorted = items.sorted { $0.bytes > $1.bytes }
            let total = sorted.reduce(0) { $0 + $1.bytes }
            return ReclaimGroup(category: category, items: sorted, totalBytes: total)
        }
        return groups.sorted { $0.totalBytes > $1.totalBytes }
    }

    private static func walk(
        _ node: FileNode,
        path: String,
        into itemsByCategory: inout [DevCategory: [ReclaimItem]]
    ) {
        if let category = node.devCategory {
            // The whole subtree is one dev item. Capture its bytes now for display stability and
            // do not descend: descendants belong to the same item, and the classifier leaves them
            // `devCategory == nil` anyway, so descending would be pure waste.
            itemsByCategory[category, default: []].append(
                ReclaimItem(node: node, path: path, bytes: node.allocatedSize)
            )
            return
        }

        // A subtree with `devSize == 0` contains no dev items, so there is nothing to collect
        // below here — skipping it makes the walk proportional to dev content, not tree size.
        // (An unclassified tree leaves `devSize` at 0 everywhere, so it yields no items at all.)
        guard node.devSize > 0, let children = node.children else { return }

        for child in children {
            let childPath = path.hasSuffix("/") ? path + child.name : path + "/" + child.name
            walk(child, path: childPath, into: &itemsByCategory)
        }
    }
}
