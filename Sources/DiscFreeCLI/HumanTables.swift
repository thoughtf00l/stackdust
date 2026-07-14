import DiscFreeCore
import Foundation

/// Human-readable (non-JSON) renderers. These produce plain text with no ANSI escapes, so
/// they are safe when stdout is redirected; sizes are right-aligned into a column for scanning.
enum HumanTables {

    // MARK: - Scan tree

    /// Renders a shaped scan tree as an indented, size-aligned table.
    static func tree(_ root: TreeNodeDTO) -> String {
        var rows: [(size: String, label: String)] = []
        collectRows(root, depth: 0, into: &rows)
        let sizeWidth = rows.map(\.size.count).max() ?? 0
        return rows
            .map { "\(padLeft($0.size, to: sizeWidth))  \($0.label)" }
            .joined(separator: "\n")
    }

    private static func collectRows(
        _ node: TreeNodeDTO,
        depth: Int,
        into rows: inout [(size: String, label: String)]
    ) {
        let indent = String(repeating: "  ", count: depth)
        var label = indent + node.name
        if node.dir { label += "/" }
        if node.unreadable == true { label += "  (unreadable)" }
        if node.cloud_evicted == true { label += "  (in iCloud)" }
        rows.append((ByteSize.human(node.bytes), label))
        for child in node.children ?? [] {
            collectRows(child, depth: depth + 1, into: &rows)
        }
    }

    // MARK: - Dev / clean item tables

    /// Renders a list of dev items as a `size  category  path` table with a total line.
    static func devItems(_ items: [DevItemDTO], totalBytes: Int64) -> String {
        guard !items.isEmpty else { return "No developer-reclaimable items found." }
        let sizeWidth = items.map { ByteSize.human($0.bytes).count }.max() ?? 0
        let categoryWidth = items.map(\.category.count).max() ?? 0
        var lines = items.map { item in
            "\(padLeft(ByteSize.human(item.bytes), to: sizeWidth))  "
                + "\(padRight(item.category, to: categoryWidth))  \(item.path)"
        }
        lines.append("total: \(ByteSize.human(totalBytes)) across \(items.count) item(s)")
        return lines.joined(separator: "\n")
    }

    /// Renders dev items grouped by category (mirrors the app's Reclaim pane): one header line
    /// per category with its display name, total size, and risk tier in brackets, its items
    /// indented beneath. Categories are ordered by total size descending, items by size
    /// descending. `items` is expected pre-sorted largest-first (as `DevSelection.collect`
    /// returns), which keeps items size-descending within each group.
    static func devItemsByCategory(_ items: [DevSelection.Item]) -> String {
        guard !items.isEmpty else { return "No developer-reclaimable items found." }

        // Bucket by category, preserving first-seen order; the incoming size-desc order is
        // stable within each bucket.
        var order: [DevCategory] = []
        var groups: [DevCategory: [DevSelection.Item]] = [:]
        for item in items {
            if groups[item.category] == nil { order.append(item.category) }
            groups[item.category, default: []].append(item)
        }
        let categoryTotals = groups.mapValues { $0.reduce(Int64(0)) { $0 + $1.bytes } }
        let orderedCategories = order.sorted { lhs, rhs in
            let lt = categoryTotals[lhs] ?? 0, rt = categoryTotals[rhs] ?? 0
            return lt != rt ? lt > rt : lhs.rawValue < rhs.rawValue
        }

        let sizeWidth = items.map { ByteSize.human($0.bytes).count }.max() ?? 0
        var lines: [String] = []
        for category in orderedCategories {
            let total = categoryTotals[category] ?? 0
            lines.append("\(category.displayName) — \(ByteSize.human(total)) [\(category.riskToken)]")
            for item in groups[category] ?? [] {
                lines.append("  \(padLeft(ByteSize.human(item.bytes), to: sizeWidth))  \(item.path)")
            }
        }
        let grandTotal = items.reduce(Int64(0)) { $0 + $1.bytes }
        lines.append("total: \(ByteSize.human(grandTotal)) across \(items.count) item(s)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Padding

    private static func padLeft(_ text: String, to width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }

    private static func padRight(_ text: String, to width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
}
