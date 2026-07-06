import SwiftUI

/// One drawable ring segment. Cheap value data: the view never walks the `FileNode`
/// tree while rendering — it renders this precomputed array. The `node` reference is
/// kept only so a click can re-focus without an index lookup.
struct SunburstSegment: Identifiable, Sendable {
    let id: ObjectIdentifier
    let node: FileNode
    let depth: Int          // ring index, 1 = innermost ring outside the hole
    let startAngle: Double  // radians in [0, 2π), 0 = top, increasing clockwise
    let endAngle: Double
    let hue: Double
    let saturation: Double
    let brightness: Double
    let isUnreadable: Bool
    /// Whether this node is a developer-reclaimable item or lives inside one.
    let isDev: Bool
    /// Whether to render this segment as a neutral gray (set only in `.devHighlight` for
    /// non-dev nodes). Kept distinct from the unreadable gray via the per-depth brightness ramp.
    let grayed: Bool

    var color: Color {
        if isUnreadable { return Color(hue: 0, saturation: 0, brightness: 0.55) }
        if grayed { return Color(hue: 0, saturation: 0, brightness: brightness) }
        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    var highlightedColor: Color {
        if isUnreadable { return Color(hue: 0, saturation: 0, brightness: 0.72) }
        if grayed { return Color(hue: 0, saturation: 0, brightness: min(1.0, brightness + 0.14)) }
        return Color(hue: hue,
                     saturation: max(0.2, saturation - 0.12),
                     brightness: min(1.0, brightness + 0.14))
    }
}

/// One row of the contents panel: a child of the focus, the size to display for the
/// current mode, and whether the child is a dev item or inside one. Precomputed off the
/// main thread alongside the sunburst so the panel never walks the tree while rendering.
struct ContentsPanelRow: Identifiable, Sendable {
    let node: FileNode
    /// Size shown for the row: `allocatedSize` in `.all`/`.devHighlight`, effective dev size
    /// in `.devOnly`.
    let displaySize: Int64
    /// True when the row is a dev-item root or inside one — not merely a container of dev items.
    let isDev: Bool

    var id: ObjectIdentifier { ObjectIdentifier(node) }
}

/// Builds the sunburst segment layout for a focus node, limited to a few depth levels
/// and culling slivers below a minimum angle. Pure and side-effect free, so it can run
/// off the main thread.
enum SunburstLayout {
    static let maxDepth = 5
    static let minAngle = 0.5 * Double.pi / 180  // 0.5° — below this a slice is invisible

    static func build(focus: FileNode, mode: DisplayMode) -> [SunburstSegment] {
        var segments: [SunburstSegment] = []
        guard let children = focus.children else { return segments }

        // "Inside a dev item" for the focus itself; threaded down the walk from here so
        // `DevClassifier.isWithinDevItem` is never called per node.
        let focusIsDev = DevClassifier.isWithinDevItem(focus)
        let total = displaySize(focus, isDev: focusIsDev, mode: mode)
        guard total > 0 else { return segments }

        // Depth 1 fills the full circle; each included top-level branch gets a distinct hue.
        let entries = sortedEntries(of: children, parentIsDev: focusIsDev, mode: mode)
        let branchCount = entries.count
        var cursor = 0.0
        for (index, entry) in entries.enumerated() {
            let extent = 2 * Double.pi * Double(entry.size) / Double(total)
            let start = cursor
            cursor += extent
            guard extent >= minAngle else { continue }  // consume the angle, skip the sliver
            let hue = branchCount > 0 ? Double(index) / Double(branchCount) : 0
            append(entry.node, depth: 1, start: start, end: cursor,
                   hue: hue, isDev: entry.isDev, mode: mode, into: &segments)
            recurse(entry.node, depth: 2, start: start, end: cursor,
                    hue: hue, nodeIsDev: entry.isDev, mode: mode, into: &segments)
        }
        return segments
    }

    /// The focus node's direct children as panel rows, sized and filtered for `mode`.
    static func rows(focus: FileNode, mode: DisplayMode) -> [ContentsPanelRow] {
        guard let children = focus.children else { return [] }
        let focusIsDev = DevClassifier.isWithinDevItem(focus)
        return sortedEntries(of: children, parentIsDev: focusIsDev, mode: mode)
            .map { ContentsPanelRow(node: $0.node, displaySize: $0.size, isDev: $0.isDev) }
    }

    /// The size shown for the focus in `mode`: `allocatedSize` normally, its effective dev
    /// total in `.devOnly`. Drives the panel share bars, the center label, and the status text.
    static func focusDisplayTotal(focus: FileNode, mode: DisplayMode) -> Int64 {
        displaySize(focus, isDev: DevClassifier.isWithinDevItem(focus), mode: mode)
    }

    private static func recurse(
        _ node: FileNode, depth: Int, start: Double, end: Double,
        hue: Double, nodeIsDev: Bool, mode: DisplayMode, into segments: inout [SunburstSegment]
    ) {
        guard depth <= maxDepth, let children = node.children else { return }
        let parentTotal = displaySize(node, isDev: nodeIsDev, mode: mode)
        guard parentTotal > 0 else { return }

        let span = end - start
        let entries = sortedEntries(of: children, parentIsDev: nodeIsDev, mode: mode)
        var cursor = start
        for entry in entries {
            let extent = span * Double(entry.size) / Double(parentTotal)
            let childStart = cursor
            cursor += extent
            guard extent >= minAngle else { continue }
            append(entry.node, depth: depth, start: childStart, end: cursor,
                   hue: hue, isDev: entry.isDev, mode: mode, into: &segments)
            recurse(entry.node, depth: depth + 1, start: childStart, end: cursor,
                    hue: hue, nodeIsDev: entry.isDev, mode: mode, into: &segments)
        }
    }

    private static func append(
        _ node: FileNode, depth: Int, start: Double, end: Double,
        hue: Double, isDev: Bool, mode: DisplayMode, into segments: inout [SunburstSegment]
    ) {
        // Outer rings get lighter, less saturated shades of the branch hue.
        let saturation = max(0.28, 0.80 - Double(depth - 1) * 0.11)
        let brightness = min(0.97, 0.70 + Double(depth - 1) * 0.06)
        segments.append(
            SunburstSegment(
                id: ObjectIdentifier(node),
                node: node,
                depth: depth,
                startAngle: start,
                endAngle: end,
                hue: hue,
                saturation: saturation,
                brightness: brightness,
                isUnreadable: node.isUnreadable,
                isDev: isDev,
                grayed: mode == .devHighlight && !isDev
            )
        )
    }

    /// Children mapped to (node, display size, isDev), zero-size entries dropped in `.devOnly`,
    /// sorted by display size descending. `parentIsDev` is the "inside a dev item" flag of the
    /// parent, threaded down so no per-node `isWithinDevItem` walk is needed.
    private static func sortedEntries(
        of children: [FileNode], parentIsDev: Bool, mode: DisplayMode
    ) -> [(node: FileNode, size: Int64, isDev: Bool)] {
        children
            .map { child -> (node: FileNode, size: Int64, isDev: Bool) in
                let isDev = parentIsDev || child.devCategory != nil
                return (child, displaySize(child, isDev: isDev, mode: mode), isDev)
            }
            .filter { mode != .devOnly || $0.size > 0 }
            .sorted { $0.size > $1.size }
    }

    /// The size a node contributes in `mode`. `isDev` is the node's own "dev item or inside
    /// one" flag: in `.devOnly` a dev node shows its whole `allocatedSize`, a non-dev node only
    /// the dev bytes aggregated beneath it (`devSize`).
    private static func displaySize(_ node: FileNode, isDev: Bool, mode: DisplayMode) -> Int64 {
        switch mode {
        case .all, .devHighlight:
            return node.allocatedSize
        case .devOnly:
            return isDev ? node.allocatedSize : node.devSize
        }
    }
}
