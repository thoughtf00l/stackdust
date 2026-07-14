import SwiftUI
import DiscFreeCore

/// The right-hand contents list: the focus node's children, largest first.
struct ContentsPanel: View {
    let focusTotal: Int64
    let rows: [ContentsPanelRow]
    /// While a foreground scan is still running the tree is mutating and sizes are lower bounds,
    /// so the Move-to-Trash affordance is hidden (the model guards it too).
    let scanActive: Bool
    @Binding var hovered: FileNode?
    let onDrill: (FileNode) -> Void
    let onReveal: (FileNode) -> Void
    let onTrash: (FileNode) -> Void

    var body: some View {
        List {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let content = ContentsRow(
                    row: row,
                    focusTotal: focusTotal,
                    hue: rows.count > 0 ? Double(index) / Double(rows.count) : 0,
                    isHovered: isRowHovered(row)
                )
                .contentShape(Rectangle())
                .onTapGesture { if let node = row.node { onDrill(node) } }
                .onHover { isInside in
                    guard let node = row.node else { return }
                    if isInside { hovered = node }
                    else if hovered === node { hovered = nil }
                }

                // The synthetic "Other" row groups the sub-threshold tail: it is not a real path,
                // so it offers neither drill nor the Reveal / Move-to-Trash context menu.
                if row.isOther {
                    content
                } else {
                    content.contextMenu {
                        Button {
                            if let node = row.node { onReveal(node) }
                        } label: {
                            Label("Reveal in Finder", systemImage: "magnifyingglass")
                        }
                        // Never offer Trash while a scan is still running: sizes are lower bounds
                        // and the tree is still mutating.
                        if !scanActive {
                            Button(role: .destructive) {
                                if let node = row.node { onTrash(node) }
                            } label: {
                                Label("Move to Trash…", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    /// Row hover highlight, matched by node identity. The synthetic "Other" row has no node, so it
    /// never highlights (and, crucially, never matches a `nil` `hovered` by accident).
    private func isRowHovered(_ row: ContentsPanelRow) -> Bool {
        guard let node = row.node else { return false }
        return hovered === node
    }
}

private struct ContentsRow: View {
    let row: ContentsPanelRow
    let focusTotal: Int64
    let hue: Double
    let isHovered: Bool

    private var share: Double {
        focusTotal > 0 ? Double(row.displaySize) / Double(focusTotal) : 0
    }

    /// Evicted (iCloud) directories render exactly like unreadable ones (gray swatch, lock glyph):
    /// both hold no local bytes and were not descended into. Nil node ("Other" row) → false.
    private var isUnreadableLike: Bool {
        guard let node = row.node else { return false }
        return node.isUnreadable || node.isCloudEvicted
    }

    private var swatch: Color {
        if row.isOther { return Color(white: 0.6) }  // neutral gray, matching the "Other" wedge
        if isUnreadableLike { return Color(white: 0.55) }
        // Same blend as the matching sunburst wedge: full color when highlighting is off
        // (fraction 1), desaturated toward gray by its reclaimable share when on.
        return SunburstSegment.tint(hue: hue, saturation: 0.7, brightness: 0.82,
                                    fraction: row.reclaimableFraction)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(isUnreadableLike ? Color.secondary : swatch)
                .frame(width: 18)

            Text(row.name)
                .lineLimit(1)
                .truncationMode(.middle)

            if row.isOther {
                Text("\(row.otherCount) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            riskBadge

            shareBar

            Text(byteString(row.displaySize))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)

            Text(percentText)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .opacity(isDrillable ? 1 : 0)
        }
        .padding(.vertical, 2)
        .listRowBackground(isHovered ? Color.accentColor.opacity(0.15) : Color.clear)
    }

    private var shareBar: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary).frame(width: 60, height: 5)
            Capsule().fill(swatch).frame(width: max(1, 60 * share), height: 5)
        }
    }

    /// The deletion-risk badge, shown only on a dev-item root (not on containers, descendants, or
    /// the synthetic "Other" row).
    @ViewBuilder
    private var riskBadge: some View {
        if let category = row.node?.devCategory {
            RiskBadge(category: category)
        }
    }

    private var isDrillable: Bool {
        guard let node = row.node else { return false }
        return node.isDirectory && node.children != nil && node.allocatedSize > 0
    }

    private var iconName: String {
        if row.isOther { return "ellipsis.circle" }
        guard let node = row.node else { return "doc.fill" }
        if isUnreadableLike { return "lock.fill" }
        return node.isDirectory ? "folder.fill" : "doc.fill"
    }

    private var percentText: String {
        share >= 0.001 ? String(format: "%.1f%%", share * 100) : "<0.1%"
    }
}
