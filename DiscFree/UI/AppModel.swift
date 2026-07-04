import SwiftUI
import Observation
import AppKit

/// Drives the whole app: the start → scanning → result state machine, the scan task and
/// its cancellation, and the (off-main-thread) sunburst layout for the current focus node.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case result
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var progress = ScanProgress(itemsScanned: 0, bytesAccumulated: 0, currentPath: "")
    private(set) var root: FileNode?
    private(set) var segments: [SunburstSegment] = []

    /// The focus node's direct children, sorted by size descending (the contents panel rows).
    private(set) var rows: [FileNode] = []

    /// Current focus (center of the sunburst). Changing it recomputes the layout.
    private(set) var focus: FileNode?

    /// Node awaiting a Move-to-Trash confirmation; non-nil drives the confirmation dialog.
    private(set) var pendingTrash: FileNode?
    /// Last deletion error; non-nil drives the error alert.
    private(set) var errorMessage: String?

    /// Whether the app can read protected locations; drives the Full Disk Access hint.
    private(set) var fullDiskAccess: FullDiskAccessStatus = .undetermined
    /// Number of unreadable directories across the whole scanned tree. Computed off the main
    /// thread once per scan and after each deletion — never walked per frame.
    private(set) var unreadableCount: Int = 0

    private let scanner = DiskScanner()
    private var scanTask: Task<Void, Never>?
    private var layoutTask: Task<Void, Never>?
    private var unreadableTask: Task<Void, Never>?

    init() {
        refreshFullDiskAccess()
    }

    /// Root-to-focus chain, for the breadcrumb.
    var focusPath: [FileNode] {
        guard let focus else { return [] }
        var chain: [FileNode] = []
        var node: FileNode? = focus
        while let current = node {
            chain.append(current)
            node = current.parent
        }
        return chain.reversed()
    }

    // MARK: - Scanning

    func startScan(at url: URL) {
        cancelScan()
        phase = .scanning
        progress = ScanProgress(itemsScanned: 0, bytesAccumulated: 0, currentPath: url.path)
        root = nil
        focus = nil
        segments = []
        rows = []
        pendingTrash = nil
        errorMessage = nil
        unreadableCount = 0

        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await update in self.scanner.scan(at: url) {
                    switch update {
                    case .progress(let progress):
                        self.progress = progress
                    case .finished(let tree):
                        self.root = tree
                        self.setFocus(tree)
                        self.phase = .result
                        self.recountUnreadable(in: tree)
                    }
                }
            } catch is CancellationError {
                self.phase = .idle
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
    }

    func returnToStart() {
        cancelScan()
        layoutTask?.cancel()
        layoutTask = nil
        phase = .idle
        root = nil
        focus = nil
        segments = []
        rows = []
        pendingTrash = nil
        errorMessage = nil
        unreadableCount = 0
        refreshFullDiskAccess()
    }

    // MARK: - Navigation

    func drill(into node: FileNode) {
        guard node.children != nil, node.allocatedSize > 0 else { return }
        setFocus(node)
    }

    func ascend() {
        if let parent = focus?.parent {
            setFocus(parent)
        }
    }

    func jump(to node: FileNode) {
        setFocus(node)
    }

    // MARK: - Layout

    private func setFocus(_ node: FileNode) {
        focus = node
        rebuild(for: node)
    }

    /// Recomputes the sunburst segments and the panel rows for `node` off the main thread.
    private func rebuild(for node: FileNode) {
        layoutTask?.cancel()
        layoutTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                () -> (segments: [SunburstSegment], rows: [FileNode]) in
                let segments = SunburstLayout.build(focus: node)
                let rows = (node.children ?? []).sorted { $0.allocatedSize > $1.allocatedSize }
                return (segments, rows)
            }.value
            guard !Task.isCancelled else { return }
            self?.segments = result.segments
            self?.rows = result.rows
        }
    }

    // MARK: - Deletion

    func reveal(_ node: FileNode) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
    }

    func requestTrash(_ node: FileNode) {
        pendingTrash = node
    }

    func cancelTrash() {
        pendingTrash = nil
    }

    func dismissError() {
        errorMessage = nil
    }

    /// Moves the pending node to the Trash, then updates the in-memory tree. On failure the
    /// tree is left unchanged and an error is surfaced.
    func confirmTrash() {
        guard let node = pendingTrash, let focus else {
            pendingTrash = nil
            return
        }
        pendingTrash = nil

        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: node.path), resultingItemURL: nil)
            try TreeEditor.remove(node, keeping: focus)
            rebuild(for: focus)
            if let root { recountUnreadable(in: root) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Full Disk Access

    func refreshFullDiskAccess() {
        fullDiskAccess = FullDiskAccessCheck().status()
    }

    /// Whether the app has read enough of the disk to be complete.
    var isFullDiskAccessMissing: Bool {
        fullDiskAccess == .denied
    }

    /// Counts unreadable directories across the whole tree off the main thread.
    private func recountUnreadable(in tree: FileNode) {
        unreadableTask?.cancel()
        unreadableTask = Task { [weak self] in
            let count = await Task.detached(priority: .utility) {
                Self.unreadableNodeCount(tree)
            }.value
            guard !Task.isCancelled else { return }
            self?.unreadableCount = count
        }
    }

    private nonisolated static func unreadableNodeCount(_ node: FileNode) -> Int {
        var count = node.isUnreadable ? 1 : 0
        if let children = node.children {
            for child in children {
                count += unreadableNodeCount(child)
            }
        }
        return count
    }
}
