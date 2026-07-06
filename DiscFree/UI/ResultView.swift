import SwiftUI
import DiscFreeCore

struct ResultView: View {
    let model: AppModel

    /// Shared between the sunburst and the contents panel for bidirectional highlighting.
    @State private var hovered: FileNode?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                BreadcrumbBar(path: model.focusPath) { model.jump(to: $0) }
                    .frame(maxWidth: .infinity, alignment: .leading)

                Picker("Display mode", selection: displayModeBinding) {
                    Text("All").tag(DisplayMode.all)
                    Text("Dev").tag(DisplayMode.devHighlight)
                    Text("Dev Only").tag(DisplayMode.devOnly)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
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
            }

            if let focus = model.focus {
                if model.displayMode == .devOnly && model.focusDisplayTotal == 0 {
                    emptyDevState
                } else {
                    HSplitView {
                        SunburstView(
                            segments: model.segments,
                            focus: focus,
                            focusTotal: model.focusDisplayTotal,
                            mode: model.displayMode,
                            onDrill: { model.drill(into: $0) },
                            onAscend: { model.ascend() },
                            hovered: $hovered
                        )
                        .frame(minWidth: 320, idealWidth: 480)
                        .padding(16)

                        ContentsPanel(
                            focusTotal: model.focusDisplayTotal,
                            rows: model.rows,
                            mode: model.displayMode,
                            hovered: $hovered,
                            onDrill: { model.drill(into: $0) },
                            onReveal: { model.reveal($0) },
                            onTrash: { model.requestTrash($0) }
                        )
                        .frame(minWidth: 300, idealWidth: 360)
                    }
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
                Spacer()
                if model.unreadableCount > 0 {
                    UnreadableIndicator(
                        count: model.unreadableCount,
                        fdaMissing: model.isFullDiskAccessMissing,
                        onOpenSettings: { FullDiskAccessCheck.openSystemSettings() }
                    )
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
            Text("“\(node.displayName)” (\(byteString(node.allocatedSize))) will be moved to the Trash.")
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
    }

    private var displayModeBinding: Binding<DisplayMode> {
        Binding(get: { model.displayMode }, set: { model.displayMode = $0 })
    }

    private var emptyDevState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("No developer items in this folder")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
