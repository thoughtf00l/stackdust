import SwiftUI
import DiscFreeCore

/// The "Reclaim" sheet: a category-first list of developer-reclaimable items with per-item and
/// per-group checkboxes, and a footer that batch-moves the selection to the Trash. Presented as a
/// sheet over `ResultView` when `reclaimPresented` is true.
struct ReclaimView: View {
    let model: AppModel

    /// Categories the user has expanded to reveal their hidden tail. A group with more than
    /// `collapsedItemLimit` items shows only its largest `collapsedItemLimit` until expanded.
    @State private var expandedCategories: Set<DevCategory> = []

    /// Max items shown per group before the rest collapse behind a "N more items" row.
    private let collapsedItemLimit = 12

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if model.scanActive {
                    emptyState("Available after the scan completes.")
                } else if model.reclaimGroups.isEmpty {
                    emptyState("Nothing reclaimable found.")
                } else {
                    content
                }
            }
        }
        .confirmationDialog(
            "Move to Trash?",
            isPresented: Binding(
                get: { model.pendingReclaimTrash != nil },
                set: { if !$0 { model.cancelReclaimTrash() } }
            ),
            presenting: model.pendingReclaimTrash
        ) { _ in
            Button("Move to Trash", role: .destructive) { model.confirmReclaimTrash() }
            Button("Cancel", role: .cancel) { model.cancelReclaimTrash() }
        } message: { pending in
            Text(trashMessage(for: pending))
        }
        // The batch trash surfaces failures via `errorMessage`. ResultView carries the same alert,
        // but while this sheet is up it covers ResultView and macOS defers a covered alert — so the
        // sheet mirrors the alert to keep failures visible. Both bind to `errorMessage`; only the
        // topmost view in the hierarchy presents, and dismissing clears the shared state for both.
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

    /// The sheet's title bar: "Reclaim", the grand total reclaimable below it, and a Done button
    /// (Escape) that dismisses the sheet. Shown in every state so the sheet is always dismissible.
    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Reclaim")
                    .font(.headline)
                if reclaimTotalBytes > 0 {
                    Text("\(byteString(reclaimTotalBytes)) reclaimable")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
            Button("Done") { model.reclaimPresented = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Grand total across every group — the sum of the per-group totals.
    private var reclaimTotalBytes: Int64 {
        model.reclaimGroups.reduce(0) { $0 + $1.totalBytes }
    }

    private func emptyState(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        VStack(spacing: 0) {
            List {
                ForEach(model.reclaimGroups, id: \.category) { group in
                    Section {
                        // The category's consequence explanation lives here — the first, non-interactive
                        // row of the section content — rather than in the header. macOS List section
                        // headers are height-constrained and clip multi-line text; a content row is not,
                        // so the caption wraps to as many lines as it needs. The invisible checkbox-width
                        // spacer keeps it aligned with the item label column below.
                        HStack(spacing: 8) {
                            Image(systemName: "square")
                                .font(.body)
                                .opacity(0)
                                .accessibilityHidden(true)
                            Text(group.category.consequence)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        let expanded = expandedCategories.contains(group.category)
                        let visible = expanded ? group.items : Array(group.items.prefix(collapsedItemLimit))
                        ForEach(visible, id: \.node.id) { item in
                            ReclaimItemRow(
                                item: item,
                                rootName: model.root?.name ?? "",
                                label: model.reclaimLabel(for: item),
                                isSelected: model.isReclaimItemSelected(item),
                                onToggle: { model.toggleReclaimItem(item) },
                                onReveal: { model.reveal(item.node) }
                            )
                        }
                        if group.items.count > collapsedItemLimit {
                            ReclaimGroupDisclosureRow(
                                hiddenCount: group.items.count - collapsedItemLimit,
                                hiddenBytes: hiddenTailBytes(group),
                                expanded: expanded,
                                onToggle: { toggleExpansion(group.category) }
                            )
                        }
                    } header: {
                        ReclaimGroupHeader(
                            group: group,
                            state: groupState(group),
                            onToggle: { model.toggleReclaimGroup(group) }
                        )
                    }
                }
            }
            .listStyle(.inset)

            Divider()
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(model.reclaimSelectedCount) items · \(byteString(model.reclaimSelectedBytes)) selected")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button {
                model.requestReclaimTrash()
            } label: {
                Text("Move Selected to Trash…")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.reclaimSelection.isEmpty || model.scanActive)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The tri-state checkbox value for a group: on when all items are selected, mixed when some
    /// are, off when none are. Computed over ALL items (not just the visible ones), so a hidden
    /// selection still shows as mixed even while the group is collapsed.
    private func groupState(_ group: ReclaimGroup) -> ReclaimCheckbox.State {
        let selected = group.items.filter { model.isReclaimItemSelected($0) }.count
        if selected == 0 { return .off }
        if selected == group.items.count { return .on }
        return .mixed
    }

    /// Combined bytes of the collapsed tail — the items past `collapsedItemLimit`. Items are sorted
    /// largest-first, so the hidden tail is always the small stuff.
    private func hiddenTailBytes(_ group: ReclaimGroup) -> Int64 {
        group.items.dropFirst(collapsedItemLimit).reduce(0) { $0 + $1.bytes }
    }

    private func toggleExpansion(_ category: DevCategory) {
        if expandedCategories.contains(category) {
            expandedCategories.remove(category)
        } else {
            expandedCategories.insert(category)
        }
    }

    private func trashMessage(for pending: AppModel.PendingReclaimTrash) -> String {
        var message = "\(pending.count) items (\(byteString(pending.bytes))) will be moved to the "
            + "Trash. Everything can be put back from the Trash."
        if pending.warnsLosesState {
            message += "\n\nSome selected items hold data that cannot be regenerated "
                + "(see their category descriptions)."
        }
        return message
    }
}

/// A minimal tap-to-toggle checkbox supporting an indeterminate (mixed) state, which the macOS
/// `Toggle` checkbox style cannot show. Used for both group headers and item rows.
private struct ReclaimCheckbox: View {
    enum State { case off, on, mixed }

    let state: State
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(state == .off ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    private var symbol: String {
        switch state {
        case .off: return "square"
        case .on: return "checkmark.square.fill"
        case .mixed: return "minus.square.fill"
        }
    }
}

/// One group's section header: a single-line control row — a tri-state checkbox that
/// selects/deselects the whole group, the category name, its risk badge, and its total. The
/// category's consequence caption is rendered as the section's first content row instead, since a
/// height-constrained macOS List header clips multi-line text.
private struct ReclaimGroupHeader: View {
    let group: ReclaimGroup
    let state: ReclaimCheckbox.State
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ReclaimCheckbox(state: state, action: onToggle)
            Text(group.category.displayName)
                .font(.headline)
            RiskBadge(category: group.category)
            Spacer(minLength: 8)
            Text(byteString(group.totalBytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// One reclaimable item: a checkbox bound to its selection, its label (a friendly device name when
/// one exists, else its path relative to the scan root), and its size. Tapping the row toggles
/// selection; the context menu reveals it in Finder.
private struct ReclaimItemRow: View {
    let item: ReclaimItem
    let rootName: String
    /// A friendly name (e.g. "iPhone 16 Pro (iOS 18.2)") when the raw path is opaque; else nil.
    let label: String?
    let isSelected: Bool
    let onToggle: () -> Void
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ReclaimCheckbox(state: isSelected ? .on : .off, action: onToggle)
            primaryText
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(byteString(item.bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .contextMenu {
            Button {
                onReveal()
            } label: {
                Label("Reveal in Finder", systemImage: "magnifyingglass")
            }
        }
    }

    /// The primary text: the friendly `label` when present (with the full path on hover, since the
    /// label hides it), otherwise the relative path.
    @ViewBuilder private var primaryText: some View {
        if let label {
            Text(label).help(item.path)
        } else {
            Text(relativePath)
        }
    }

    /// `item.path` with the scan root's absolute-path prefix (`rootName`) stripped, so a deep item
    /// reads as its location within the scan rather than a full absolute path. Falls back to the
    /// absolute path if the prefix does not match.
    private var relativePath: String {
        guard !rootName.isEmpty, item.path.hasPrefix(rootName) else { return item.path }
        var remainder = String(item.path.dropFirst(rootName.count))
        if remainder.hasPrefix("/") { remainder.removeFirst() }
        return remainder.isEmpty ? item.path : remainder
    }
}

/// The trailing row of a group with more than `collapsedItemLimit` items: shows how much is hidden
/// ("N more items · size") while collapsed, "Show less" while expanded, and toggles the group's
/// expansion when tapped. Purely visual — the group's checkbox still operates on every item.
private struct ReclaimGroupDisclosureRow: View {
    let hiddenCount: Int
    let hiddenBytes: Int64
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(expanded ? "Show less" : "\(hiddenCount) more items · \(byteString(hiddenBytes))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }
}
