import SwiftUI
import StackdustCore

/// One drawable ring segment. Cheap value data: the view never walks the `FileNode`
/// tree while rendering — it renders this precomputed array. The `node` reference is
/// kept only so a click can re-focus without an index lookup.
struct SunburstSegment: Identifiable, Sendable {
    /// Unique within one layout pass (the segment's index in the built array). Real-node segments
    /// are matched for hover by node identity; the synthetic "Other" wedge — which has no node —
    /// is matched by this id.
    let id: Int
    /// The file-tree node this segment draws, or `nil` for the synthetic "Other" wedge that groups
    /// a directory's sub-threshold tail.
    let node: FileNode?
    /// Label for the center hover readout: the node's `displayName`, or "Other".
    let label: String
    /// Size for the center hover readout: the node's `allocatedSize`, or the combined tail bytes.
    let size: Int64
    let depth: Int          // ring index, 1 = innermost ring outside the hole
    let startAngle: Double  // radians in [0, 2π), 0 = top, increasing clockwise
    let endAngle: Double
    let hue: Double
    let saturation: Double
    let brightness: Double
    let isUnreadable: Bool
    /// Whether this node is a developer-reclaimable item or lives inside one.
    let isDev: Bool
    /// The node's reclaimable share, used to tint the segment when highlighting: 1 for a dev
    /// item and its descendants, `devSize / allocatedSize` for any other node (0 when
    /// `allocatedSize == 0`). Only meaningful while highlighting; it is 1 when highlighting is
    /// off, so `color` reproduces the full branch color unchanged.
    let reclaimableFraction: Double

    /// True for the synthetic "Other" wedge (no backing node).
    var isOther: Bool { node == nil }

    var color: Color {
        if isUnreadable { return Color(hue: 0, saturation: 0, brightness: 0.55) }
        return tinted(saturation: saturation, brightness: brightness)
    }

    var highlightedColor: Color {
        if isUnreadable { return Color(hue: 0, saturation: 0, brightness: 0.72) }
        return tinted(saturation: max(0.2, saturation - 0.12),
                      brightness: min(1.0, brightness + 0.14))
    }

    private func tinted(saturation fullSaturation: Double, brightness fullBrightness: Double) -> Color {
        SunburstSegment.tint(hue: hue, saturation: fullSaturation,
                             brightness: fullBrightness, fraction: reclaimableFraction)
    }

    /// Blends the full branch color `(hue, saturation, brightness)` toward its neutral gray
    /// (same hue, saturation 0, same brightness) by `sqrt(fraction)`: saturation scales toward 0
    /// and brightness interpolates toward the gray's value. The `sqrt` gives a perceptual boost so
    /// even a small reclaimable share stays visibly warm. Fraction 1 reproduces the full color;
    /// fraction 0 collapses to the plain gray, matching the old all-gray look. (Brightness
    /// blending is a no-op while both endpoints share the ramp, kept general so the blend stays
    /// correct if they ever diverge.) Shared by the sunburst segments and the contents-panel rows
    /// so a node's wedge and its row always tint by the same curve toward the same gray.
    static func tint(hue: Double, saturation: Double, brightness: Double, fraction: Double) -> Color {
        let t = min(1, max(0, fraction)).squareRoot()
        let grayBrightness = brightness
        return Color(hue: hue,
                     saturation: saturation * t,
                     brightness: grayBrightness + (brightness - grayBrightness) * t)
    }
}

/// One row of the contents panel: a child of the focus, its display size, and whether the
/// child is a dev item or inside one. Precomputed off the main thread alongside the sunburst
/// so the panel never walks the tree while rendering.
struct ContentsPanelRow: Identifiable, Sendable {
    /// The child node this row shows, or `nil` for the synthetic "Other" row that groups a
    /// directory's sub-threshold tail.
    let node: FileNode?
    /// Size shown for the row: the node's `allocatedSize`, or the combined tail bytes.
    let displaySize: Int64
    /// True when the row is a dev-item root or inside one — not merely a container of dev items.
    /// Always false for the "Other" row.
    let isDev: Bool
    /// Row label: the node's `displayName`, or "Other".
    let name: String
    /// For the "Other" row, the number of grouped tail items; 0 for a normal row.
    let otherCount: Int
    /// The row's reclaimable share, mirroring the matching wedge's `reclaimableFraction`: 1 for a
    /// dev item and its descendants, `devSize / allocatedSize` for a container, the tail's combined
    /// share for the "Other" row. Only meaningful while highlighting; it is forced to 1 when
    /// highlighting is off, so the row's swatch reproduces its full color unchanged.
    let reclaimableFraction: Double

    /// True for the synthetic "Other" row (no backing node).
    var isOther: Bool { node == nil }

    var id: RowID { node.map { RowID.node(ObjectIdentifier($0)) } ?? .other }
}

/// Stable identity for a contents-panel row within one layout pass. A directory yields at most
/// one "Other" row, so the `.other` case is unique.
enum RowID: Hashable, Sendable {
    case node(ObjectIdentifier)
    case other
}

/// Builds the sunburst segment layout for a focus node, limited to a few depth levels
/// and culling slivers below a minimum angle. Pure and side-effect free, so it can run
/// off the main thread.
enum SunburstLayout {
    static let maxDepth = 5
    static let minAngle = 0.5 * Double.pi / 180  // 0.5° — below this a slice is invisible

    static func build(focus: FileNode, highlight: Bool) -> [SunburstSegment] {
        var segments: [SunburstSegment] = []
        guard let children = focus.children else { return segments }

        // "Inside a dev item" for the focus itself; threaded down the walk from here so
        // `DevClassifier.isWithinDevItem` is never called per node.
        let focusIsDev = DevClassifier.isWithinDevItem(focus)
        let total = focus.allocatedSize
        guard total > 0 else { return segments }

        // Depth 1 fills the full circle; each included top-level branch gets a distinct hue.
        let entries = sortedEntries(of: children, parentIsDev: focusIsDev)
        let (head, tail) = splitTail(entries, focusTotal: total)
        // Hue is assigned per drawn depth-1 slot; the panel colors its rows the same way, so the
        // denominator must match the panel row count (head entries + one "Other" row when grouping).
        let branchCount = head.count + (tail.isEmpty ? 0 : 1)
        var cursor = 0.0
        for (index, entry) in head.enumerated() {
            let extent = 2 * Double.pi * Double(entry.size) / Double(total)
            let start = cursor
            cursor += extent
            guard extent >= minAngle else { continue }  // consume the angle, skip the sliver
            let hue = branchCount > 0 ? Double(index) / Double(branchCount) : 0
            append(entry.node, depth: 1, start: start, end: cursor, hue: hue,
                   isDev: entry.isDev, fraction: entry.fraction, highlight: highlight,
                   into: &segments)
            recurse(entry.node, depth: 2, start: start, end: cursor,
                    hue: hue, nodeIsDev: entry.isDev, focusTotal: total, highlight: highlight,
                    into: &segments)
        }
        // The grouped tail fills the ring from where the drawn head ended to the full circle,
        // closing the gap the minAngle cull would otherwise leave.
        if !tail.isEmpty {
            appendOther(tail, depth: 1, start: cursor, end: 2 * Double.pi,
                        highlight: highlight, into: &segments)
        }
        return segments
    }

    /// The focus node's direct children as panel rows, sized by `allocatedSize`. The
    /// sub-threshold tail is folded into one trailing "Other" row, mirroring the chart's grouping.
    /// `highlight` carries the reclaimable share into each row exactly as `build(focus:highlight:)`
    /// carries it into the wedges, so a row and its wedge tint identically.
    static func rows(focus: FileNode, highlight: Bool) -> [ContentsPanelRow] {
        guard let children = focus.children else { return [] }
        let focusIsDev = DevClassifier.isWithinDevItem(focus)
        let entries = sortedEntries(of: children, parentIsDev: focusIsDev)
        let (head, tail) = splitTail(entries, focusTotal: focus.allocatedSize)
        var rows = head.map {
            ContentsPanelRow(node: $0.node, displaySize: $0.size, isDev: $0.isDev,
                             name: $0.node.displayName, otherCount: 0,
                             // Highlighting off: full color, so the fraction is forced to 1.
                             reclaimableFraction: highlight ? $0.fraction : 1)
        }
        if !tail.isEmpty {
            let size = tail.reduce(Int64(0)) { $0 + $1.size }
            // Combined reclaimable share of the grouped tail, matching the "Other" wedge in
            // `appendOther`: `fraction * size` is each entry's reclaimable bytes, summed over size.
            let devBytes = tail.reduce(0.0) { $0 + $1.fraction * Double($1.size) }
            let fraction = size > 0 ? devBytes / Double(size) : 0
            rows.append(ContentsPanelRow(node: nil, displaySize: size, isDev: false,
                                         name: "Other", otherCount: tail.count,
                                         reclaimableFraction: highlight ? fraction : 1))
        }
        return rows
    }

    /// The focus's `allocatedSize`. Drives the panel share bars, the center label, and the
    /// status text.
    static func focusDisplayTotal(focus: FileNode) -> Int64 {
        focus.allocatedSize
    }

    private static func recurse(
        _ node: FileNode, depth: Int, start: Double, end: Double,
        hue: Double, nodeIsDev: Bool, focusTotal: Int64, highlight: Bool,
        into segments: inout [SunburstSegment]
    ) {
        guard depth <= maxDepth, let children = node.children else { return }
        let parentTotal = node.allocatedSize
        guard parentTotal > 0 else { return }

        let span = end - start
        let entries = sortedEntries(of: children, parentIsDev: nodeIsDev)
        let (head, tail) = splitTail(entries, focusTotal: focusTotal)
        var cursor = start
        for entry in head {
            let extent = span * Double(entry.size) / Double(parentTotal)
            let childStart = cursor
            cursor += extent
            guard extent >= minAngle else { continue }
            append(entry.node, depth: depth, start: childStart, end: cursor, hue: hue,
                   isDev: entry.isDev, fraction: entry.fraction, highlight: highlight,
                   into: &segments)
            recurse(entry.node, depth: depth + 1, start: childStart, end: cursor,
                    hue: hue, nodeIsDev: entry.isDev, focusTotal: focusTotal, highlight: highlight,
                    into: &segments)
        }
        if !tail.isEmpty {
            appendOther(tail, depth: depth, start: cursor, end: end,
                        highlight: highlight, into: &segments)
        }
    }

    private static func append(
        _ node: FileNode, depth: Int, start: Double, end: Double, hue: Double,
        isDev: Bool, fraction: Double, highlight: Bool, into segments: inout [SunburstSegment]
    ) {
        // Outer rings get lighter, less saturated shades of the branch hue.
        let saturation = max(0.28, 0.80 - Double(depth - 1) * 0.11)
        let brightness = min(0.97, 0.70 + Double(depth - 1) * 0.06)
        segments.append(
            SunburstSegment(
                id: segments.count,
                node: node,
                label: node.displayName,
                size: node.allocatedSize,
                depth: depth,
                startAngle: start,
                endAngle: end,
                hue: hue,
                saturation: saturation,
                brightness: brightness,
                // Evicted (iCloud) directories render exactly like unreadable ones — gray, no new
                // color. They are 0-byte so they are almost always minAngle-culled anyway.
                isUnreadable: node.isUnreadable || node.isCloudEvicted,
                isDev: isDev,
                // Highlighting off: full color, so the fraction is forced to 1.
                reclaimableFraction: highlight ? fraction : 1
            )
        )
    }

    /// Appends one neutral-gray "Other" wedge spanning `[start, end]` for a directory's grouped
    /// sub-threshold tail. It is never recursed into. Gray = hue 0 + saturation 0 with the same
    /// per-depth brightness ramp as `append`, so it reads as "misc, grouped" rather than a branch
    /// color; the honest combined reclaimable share is still recorded in `reclaimableFraction`.
    private static func appendOther(
        _ tail: ArraySlice<Entry>, depth: Int, start: Double, end: Double,
        highlight: Bool, into segments: inout [SunburstSegment]
    ) {
        let size = tail.reduce(Int64(0)) { $0 + $1.size }
        // `fraction * size` is each entry's reclaimable bytes (devSize for a container, the full
        // size for a dev item), so the sum over size is the tail's combined reclaimable share.
        let devBytes = tail.reduce(0.0) { $0 + $1.fraction * Double($1.size) }
        let fraction = size > 0 ? devBytes / Double(size) : 0
        let brightness = min(0.97, 0.70 + Double(depth - 1) * 0.06)
        segments.append(
            SunburstSegment(
                id: segments.count,
                node: nil,
                label: "Other",
                size: size,
                depth: depth,
                startAngle: start,
                endAngle: end,
                hue: 0,
                saturation: 0,
                brightness: brightness,
                isUnreadable: false,
                isDev: false,
                reclaimableFraction: highlight ? fraction : 1
            )
        )
    }

    /// A sized, classified child of some directory. `fraction` is 1 for a dev node (item or
    /// descendant), otherwise its `devSize / allocatedSize` share (0 when empty).
    private typealias Entry = (node: FileNode, size: Int64, isDev: Bool, fraction: Double)

    /// Fraction of the focus total below which an entry is "tiny": 0.1%. Sunburst angles nest
    /// proportionally, so any node's angular fraction of the full circle equals `size / focusTotal`
    /// — the same base the angles use. A tiny entry is therefore always a sub-0.36° sliver that
    /// the `minAngle` cull would drop, leaving a silent gap.
    static let tailFraction = 0.001

    /// Splits size-sorted `entries` into the drawn head and the grouped tail. The tail is the
    /// contiguous suffix of entries each below `tailFraction` of `focusTotal`, and is returned only
    /// when it holds ≥ 2 entries — a lone tiny entry stays in the head and is drawn (and possibly
    /// minAngle-culled) as-is. Grouping the tail into one "Other" wedge closes the ring gap that
    /// mass-culling slivers would otherwise leave.
    private static func splitTail(
        _ entries: [Entry], focusTotal: Int64
    ) -> (head: ArraySlice<Entry>, tail: ArraySlice<Entry>) {
        let threshold = tailFraction * Double(focusTotal)
        var split = entries.count
        while split > 0, Double(entries[split - 1].size) < threshold {
            split -= 1
        }
        guard entries.count - split >= 2 else { return (entries[...], entries[entries.count...]) }
        return (entries[..<split], entries[split...])
    }

    /// Children mapped to `Entry`, sorted by size descending. `parentIsDev` is the "inside a dev
    /// item" flag of the parent, threaded down so no per-node `isWithinDevItem` walk is needed.
    private static func sortedEntries(
        of children: [FileNode], parentIsDev: Bool
    ) -> [Entry] {
        children
            .map { child -> Entry in
                let isDev = parentIsDev || child.devCategory != nil
                let fraction: Double
                if isDev {
                    fraction = 1
                } else if child.allocatedSize > 0 {
                    fraction = Double(child.devSize) / Double(child.allocatedSize)
                } else {
                    fraction = 0
                }
                return (child, child.allocatedSize, isDev, fraction)
            }
            .sorted { $0.size > $1.size }
    }
}
