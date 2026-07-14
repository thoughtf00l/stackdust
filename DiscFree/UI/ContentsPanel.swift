import SwiftUI
import DiscFreeCore

/// The right-hand contents list: the focus node's children, largest first.
struct ContentsPanel: View {
    let focusTotal: Int64
    let rows: [ContentsPanelRow]
    let mode: DisplayMode
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
                ContentsRow(
                    row: row,
                    focusTotal: focusTotal,
                    mode: mode,
                    hue: rows.count > 0 ? Double(index) / Double(rows.count) : 0,
                    isHovered: hovered === row.node
                )
                .contentShape(Rectangle())
                .onTapGesture { onDrill(row.node) }
                .onHover { isInside in
                    if isInside { hovered = row.node }
                    else if hovered === row.node { hovered = nil }
                }
                .contextMenu {
                    Button {
                        onReveal(row.node)
                    } label: {
                        Label("Reveal in Finder", systemImage: "magnifyingglass")
                    }
                    // In .devOnly a container that merely holds dev items must not offer Trash:
                    // trashing it would delete the non-dev content the mode hides. And never
                    // while a scan is still running (sizes are lower bounds, tree is mutating).
                    if !scanActive && (mode != .devOnly || row.isDev) {
                        Button(role: .destructive) {
                            onTrash(row.node)
                        } label: {
                            Label("Move to Trash…", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

private struct ContentsRow: View {
    let row: ContentsPanelRow
    let focusTotal: Int64
    let mode: DisplayMode
    let hue: Double
    let isHovered: Bool

    private var node: FileNode { row.node }

    private var share: Double {
        focusTotal > 0 ? Double(row.displaySize) / Double(focusTotal) : 0
    }

    private var swatch: Color {
        if node.isUnreadable { return Color(white: 0.55) }
        // Match the sunburst: non-dev rows go gray in .devHighlight, kept distinct from the
        // unreadable gray by a lighter shade.
        if mode == .devHighlight && !row.isDev { return Color(hue: 0, saturation: 0, brightness: 0.72) }
        return Color(hue: hue, saturation: 0.7, brightness: 0.82)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(node.isUnreadable ? Color.secondary : swatch)
                .frame(width: 18)

            Text(node.displayName)
                .lineLimit(1)
                .truncationMode(.middle)

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

    /// A subdued capsule showing the deletion risk of a dev-item root (only on the root
    /// itself, not on containers or descendants). Hovering it explains the consequence.
    @ViewBuilder
    private var riskBadge: some View {
        if let category = node.devCategory {
            let tier = category.riskTier
            Text(riskLabel(tier))
                .font(.caption2)
                .foregroundStyle(riskColor(tier))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(riskColor(tier).opacity(0.18)))
                .help(category.consequence)
        }
    }

    private func riskLabel(_ tier: DevRiskTier) -> String {
        switch tier {
        case .safe: return "Safe"
        case .costsTime: return "Costs time"
        case .losesState: return "Loses data"
        }
    }

    private func riskColor(_ tier: DevRiskTier) -> Color {
        switch tier {
        case .safe: return .green
        case .costsTime: return .yellow
        case .losesState: return .orange
        }
    }

    private var isDrillable: Bool {
        node.isDirectory && node.children != nil && node.allocatedSize > 0
    }

    private var iconName: String {
        if node.isUnreadable { return "lock.fill" }
        return node.isDirectory ? "folder.fill" : "doc.fill"
    }

    private var percentText: String {
        share >= 0.001 ? String(format: "%.1f%%", share * 100) : "<0.1%"
    }
}
