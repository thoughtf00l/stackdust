import DiscFreeCore
import Foundation

/// Turns a scanned `FileNode` tree into a bounded, sorted `TreeNodeDTO` for output.
///
/// Bounding happens on three independent axes, any of which sets `truncated` when it drops
/// something:
/// - `maxDepth`: how many levels of children below the root to include (0 = root only).
/// - `top`: the largest N children kept per directory (the rest are dropped).
/// - `minSize`: children smaller than this are dropped.
///
/// Children are always ordered largest-first, with name as a tiebreaker so output is stable.
enum TreeShaper {

    struct Options {
        var maxDepth: Int
        var top: Int
        var minSize: Int64
    }

    struct Result {
        let node: TreeNodeDTO
        /// True when depth, top, or min-size caused any node to be omitted.
        let truncated: Bool
    }

    static func shape(_ root: FileNode, options: Options) -> Result {
        var truncated = false
        let node = shapeNode(root, remainingDepth: options.maxDepth, options: options, truncated: &truncated)
        return Result(node: node, truncated: truncated)
    }

    private static func shapeNode(
        _ node: FileNode,
        remainingDepth: Int,
        options: Options,
        truncated: inout Bool
    ) -> TreeNodeDTO {
        let unreadable: Bool? = node.isUnreadable ? true : nil
        let cloudEvicted: Bool? = node.isCloudEvicted ? true : nil

        guard node.isDirectory else {
            return TreeNodeDTO(
                name: node.name, bytes: node.allocatedSize, dir: false,
                unreadable: unreadable, cloud_evicted: cloudEvicted, children: nil
            )
        }

        let allChildren = node.children ?? []

        // Depth cut: keep the directory node but do not descend. If it actually holds
        // children, that is dropped data.
        if remainingDepth <= 0 {
            if !allChildren.isEmpty { truncated = true }
            return TreeNodeDTO(
                name: node.name, bytes: node.allocatedSize, dir: true,
                unreadable: unreadable, cloud_evicted: cloudEvicted, children: []
            )
        }

        var kept = allChildren

        if options.minSize > 0 {
            let before = kept.count
            kept = kept.filter { $0.allocatedSize >= options.minSize }
            if kept.count != before { truncated = true }
        }

        kept.sort { lhs, rhs in
            lhs.allocatedSize != rhs.allocatedSize
                ? lhs.allocatedSize > rhs.allocatedSize
                : lhs.name < rhs.name
        }

        if options.top >= 0, kept.count > options.top {
            kept = Array(kept.prefix(options.top))
            truncated = true
        }

        let childNodes = kept.map {
            shapeNode($0, remainingDepth: remainingDepth - 1, options: options, truncated: &truncated)
        }
        return TreeNodeDTO(
            name: node.name, bytes: node.allocatedSize, dir: true,
            unreadable: unreadable, cloud_evicted: cloudEvicted, children: childNodes
        )
    }

    /// Counts nodes flagged unreadable (genuine read failures) across the whole tree, independent
    /// of any bounding, so the reported `unreadable_count` reflects the real scan rather than the
    /// shaped view. iCloud-evicted directories are not counted here (see `countCloudEvicted`).
    static func countUnreadable(_ root: FileNode) -> Int {
        var count = 0
        var stack: [FileNode] = [root]
        while let node = stack.popLast() {
            if node.isUnreadable { count += 1 }
            if let children = node.children { stack.append(contentsOf: children) }
        }
        return count
    }

    /// Counts iCloud-evicted (dataless) directories across the whole tree, independent of any
    /// bounding. These are directories the scanner deliberately did not descend into because
    /// their content lives in the cloud and occupies ~no local disk space.
    static func countCloudEvicted(_ root: FileNode) -> Int {
        var count = 0
        var stack: [FileNode] = [root]
        while let node = stack.popLast() {
            if node.isCloudEvicted { count += 1 }
            if let children = node.children { stack.append(contentsOf: children) }
        }
        return count
    }
}
