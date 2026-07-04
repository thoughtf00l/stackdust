import SwiftUI

struct ResultView: View {
    let model: AppModel

    /// Shared between the sunburst and the contents panel for bidirectional highlighting.
    @State private var hovered: FileNode?

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbBar(path: model.focusPath) { model.jump(to: $0) }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            if let focus = model.focus {
                HSplitView {
                    SunburstView(
                        segments: model.segments,
                        focus: focus,
                        onDrill: { model.drill(into: $0) },
                        onAscend: { model.ascend() },
                        hovered: $hovered
                    )
                    .frame(minWidth: 320, idealWidth: 480)
                    .padding(16)

                    ContentsPanel(
                        focusTotal: focus.allocatedSize,
                        rows: model.rows,
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
                    Text("\(focus.displayName) — \(byteString(focus.allocatedSize))")
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
