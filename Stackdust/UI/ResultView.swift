import SwiftUI
import StackdustCore

struct ResultView: View {
    let model: AppModel

    /// Shared between the sunburst and the contents panel for bidirectional highlighting.
    @State private var hovered: FileNode?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                BreadcrumbBar(path: model.focusPath) { model.jump(to: $0) }
                    .frame(maxWidth: .infinity, alignment: .leading)

                Toggle("Highlight reclaimable", isOn: highlightBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .fixedSize()

                Button {
                    model.reclaimPresented = true
                } label: {
                    Label("Reclaim…", systemImage: "arrow.up.trash")
                }
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if model.refreshProgress != nil {
                RefreshBar(
                    fraction: model.refreshFraction,
                    bytesScanned: model.refreshProgress?.bytesAccumulated ?? 0,
                    dataDate: model.lastScanDate
                )
                Divider()
            } else if model.scanActive {
                ScanningBar(
                    itemsScanned: model.progress.itemsScanned,
                    bytesAccumulated: model.progress.bytesAccumulated,
                    onCancel: { model.returnToStart() }
                )
                Divider()
            }

            if let focus = model.focus {
                HSplitView {
                    SunburstView(
                        segments: model.segments,
                        focus: focus,
                        focusTotal: model.focusDisplayTotal,
                        onDrill: { model.drill(into: $0) },
                        onAscend: { model.ascend() },
                        hovered: $hovered
                    )
                    .frame(minWidth: 320, idealWidth: 480)
                    .padding(16)

                    ContentsPanel(
                        focusTotal: model.focusDisplayTotal,
                        rows: model.rows,
                        palette: model.themePalette,
                        scanActive: model.scanActive,
                        hovered: $hovered,
                        onDrill: { model.drill(into: $0) },
                        onReveal: { model.reveal($0) },
                        onTrash: { model.requestTrash($0) }
                    )
                    .frame(minWidth: 300, idealWidth: 360)
                }
            } else {
                Spacer()
            }

            Divider()

            HStack(spacing: 12) {
                Button {
                    model.returnToStart()
                } label: {
                    Label("New Scan", systemImage: "arrow.left")
                }
                if let free = model.freeSpaceBytes {
                    Text("\(byteString(free)) free")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .help("Free space on this volume, including purgeable space — the figure Finder shows. Items moved to the Trash free space only once the Trash is emptied.")
                }
                if model.reclaimedTotalBytes > 0 {
                    Label("\(byteString(model.reclaimedTotalBytes)) reclaimed", systemImage: "sparkles")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .help("Total Stackdust has moved to the Trash on this Mac, across all sessions.")
                }
                Spacer()
                if model.unreadableCount > 0 {
                    UnreadableIndicator(
                        count: model.unreadableCount,
                        fdaMissing: model.isFullDiskAccessMissing,
                        onOpenSettings: { FullDiskAccessCheck.openSystemSettings() }
                    )
                    .font(.callout)
                }
                if model.cloudEvictedCount > 0 {
                    CloudEvictedIndicator(count: model.cloudEvictedCount)
                        .font(.callout)
                }
                if let focus = model.focus {
                    Text("\(focus.displayName) — \(byteString(model.focusDisplayTotal))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .confirmationDialog(
            "Move to Trash?",
            isPresented: Binding(
                get: { model.pendingTrash != nil },
                set: { if !$0 { model.cancelTrash() } }
            ),
            presenting: model.pendingTrash
        ) { _ in
            Button("Move to Trash", role: .destructive) { model.confirmTrash() }
            Button("Cancel", role: .cancel) { model.cancelTrash() }
        } message: { node in
            Text(trashMessage(for: node))
        }
        .alert(
            "Couldn’t Move to Trash",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.dismissError() } }
            ),
            presenting: model.errorMessage
        ) { _ in
            Button("OK", role: .cancel) { model.dismissError() }
        } message: { message in
            Text(message)
        }
        .sheet(isPresented: reclaimPresentedBinding) {
            ReclaimView(model: model)
                .frame(
                    minWidth: 560, idealWidth: 640,
                    minHeight: 480, idealHeight: 620
                )
        }
    }

    private var highlightBinding: Binding<Bool> {
        Binding(get: { model.highlightReclaimable }, set: { model.highlightReclaimable = $0 })
    }

    private var reclaimPresentedBinding: Binding<Bool> {
        Binding(get: { model.reclaimPresented }, set: { model.reclaimPresented = $0 })
    }

    /// The Move-to-Trash prompt. For a dev-item root, the category's consequence is appended
    /// after a blank line so the user sees what deleting it costs; non-dev nodes get the base
    /// message only.
    private func trashMessage(for node: FileNode) -> String {
        let base = "“\(node.displayName)” (\(byteString(node.allocatedSize))) will be moved to the Trash."
        if let category = node.devCategory {
            return base + "\n\n" + category.consequence
        }
        return base
    }
}

/// The thin strip shown while a background rescan refreshes a cache-loaded tree: a progress
/// bar (byte-based against the previous scan's total, indeterminate when unknown) plus a
/// caption naming the on-screen data's age.
private struct RefreshBar: View {
    let fraction: Double?
    let bytesScanned: Int64
    let dataDate: Date?

    var body: some View {
        HStack(spacing: 10) {
            if let fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var caption: String {
        var text = "Refreshing — \(byteString(bytesScanned)) scanned"
        if let dataDate {
            text += " · data from \(dataDate.formatted(date: .omitted, time: .shortened))"
        }
        return text
    }
}

/// The thin strip shown while a foreground scan is still running under the browser: an
/// indeterminate progress bar plus a live item/byte count and a compact Cancel that abandons the
/// scan and returns to the picker. Mirrors `RefreshBar`'s layout; the two never show at once
/// (background refresh only runs for cache-loaded trees, `scanActive` only for foreground scans).
private struct ScanningBar: View {
    let itemsScanned: Int
    let bytesAccumulated: Int64
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .progressViewStyle(.linear)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            Button("Cancel", action: onCancel)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var caption: String {
        "Scanning… \(itemsScanned.formatted()) items · \(byteString(bytesAccumulated))"
    }
}

/// Horizontally scrolling breadcrumb of the focus path; the last crumb is the focus.
struct BreadcrumbBar: View {
    let path: [FileNode]
    let onSelect: (FileNode) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(path.enumerated()), id: \.offset) { index, node in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        onSelect(node)
                    } label: {
                        Text(node.displayName)
                            .lineLimit(1)
                            .fontWeight(index == path.count - 1 ? .bold : .regular)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct FailedView: View {
    let model: AppModel
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("Scan failed")
                .font(.title2.bold())
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button {
                model.returnToStart()
            } label: {
                Label("Back", systemImage: "arrow.left")
            }
        }
        .padding(40)
    }
}
