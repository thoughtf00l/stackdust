import StackdustCore
import Foundation

/// Selects developer-reclaimable item roots from a classified `FileNode` tree.
///
/// The tree must already have been passed through `DevClassifier.classify`. Only the outermost
/// matched nodes carry a `devCategory`, so collecting every node with a non-nil `devCategory`
/// yields exactly the item roots, never a nested duplicate.
enum DevSelection {

    /// A selected item: its absolute path, category, and aggregated size on disk.
    struct Item: Equatable {
        let path: String
        let category: DevCategory
        let bytes: Int64
    }

    /// Walks the classified tree and returns the item roots, sorted largest-first (path as a
    /// stable tiebreaker).
    static func collect(_ root: FileNode) -> [Item] {
        var items: [Item] = []
        var stack: [FileNode] = [root]
        while let node = stack.popLast() {
            if let category = node.devCategory {
                items.append(Item(path: node.path, category: category, bytes: node.allocatedSize))
                // A match is a whole item; its descendants are inside it, not separate items.
                continue
            }
            if let children = node.children { stack.append(contentsOf: children) }
        }
        return sorted(items)
    }

    /// Filters items by an optional category set and a minimum size, preserving the sort order.
    static func filter(
        _ items: [Item],
        categories: Set<DevCategory>?,
        minSize: Int64
    ) -> [Item] {
        items.filter { item in
            if let categories, !categories.contains(item.category) { return false }
            if item.bytes < minSize { return false }
            return true
        }
    }

    private static func sorted(_ items: [Item]) -> [Item] {
        items.sorted { lhs, rhs in
            lhs.bytes != rhs.bytes ? lhs.bytes > rhs.bytes : lhs.path < rhs.path
        }
    }
}

extension DevCategory {
    /// The category's risk tier as this CLI's snake_case token (`safe` / `costs_time` /
    /// `loses_state`). Distinct from `DevRiskTier.rawValue`, which is camelCase and must stay
    /// unchanged; the CLI's JSON keys and values are snake_case (e.g. `total_bytes`).
    var riskToken: String {
        switch riskTier {
        case .safe: return "safe"
        case .costsTime: return "costs_time"
        case .losesState: return "loses_state"
        }
    }
}
