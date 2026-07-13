import SwiftUI
import Observation
import AppKit
import DiscFreeCore

/// How the sunburst and contents panel present the tree.
enum DisplayMode: Sendable {
    /// Every node, sized by `allocatedSize`. The default.
    case all
    /// Same geometry and sizes as `.all`, but nodes outside a dev item are drawn gray.
    case devHighlight
    /// Only developer-reclaimable items, sized by their dev bytes.
    case devOnly
}

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

    /// True from `startScan` until the scan finishes, fails, or is cancelled. Drives everything
    /// scan-specific in the result view (the scanning strip, the trash lock). Distinct from
    /// `phase`: `.scanning` is only the sub-second window before the first partial arrives; the
    /// UI switches to `.result` and browses the growing tree while `scanActive` stays true.
    private(set) var scanActive: Bool = false

    private(set) var progress = ScanProgress(itemsScanned: 0, bytesAccumulated: 0, currentPath: "")
    private(set) var root: FileNode?
    private(set) var segments: [SunburstSegment] = []

    /// The focus node's direct children as panel rows, sized and filtered for `displayMode`.
    private(set) var rows: [ContentsPanelRow] = []

    /// The size shown for the current focus in `displayMode` (its `allocatedSize`, or its
    /// effective dev total in `.devOnly`). Drives share bars, the center label, and the status.
    private(set) var focusDisplayTotal: Int64 = 0

    /// The presentation mode. Changing it recomputes the layout for the current focus.
    var displayMode: DisplayMode = .all {
        didSet {
            guard displayMode != oldValue, let focus else { return }
            rebuild(for: focus)
        }
    }

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

    /// When the tree on screen was produced by a scan. Comes from the snapshot header when
    /// the tree was loaded from cache, or "now" when a scan finishes.
    private(set) var lastScanDate: Date?
    /// Non-nil while a background rescan of a cache-loaded tree is running; drives the
    /// refresh bar in the result view.
    private(set) var refreshProgress: ScanProgress?
    /// The cached tree's total bytes, used to estimate background-rescan progress.
    private var expectedRefreshBytes: Int64 = 0

    /// Fraction for the refresh bar: bytes scanned against the previous scan's total,
    /// saturating below 1 because the disk may have grown since. Nil → indeterminate.
    var refreshFraction: Double? {
        guard let refreshProgress, expectedRefreshBytes > 0 else { return nil }
        return min(0.99, Double(refreshProgress.bytesAccumulated) / Double(expectedRefreshBytes))
    }

    private let scanner = DiskScanner()
    private let catalog = DevItemCatalog()
    private let snapshotStore = SnapshotStore()
    private var scanTask: Task<Void, Never>?
    private var layoutTask: Task<Void, Never>?
    /// Focus-steering handle for the running foreground scan. Non-nil between `.started` and the
    /// scan's end; the UI writes the current focus path here (via `setFocus`) so each partial
    /// snapshot follows where the user has navigated.
    private var liveScan: LiveScan?
    private var unreadableTask: Task<Void, Never>?
    private var classifyTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var snapshotSaveTask: Task<Void, Never>?
    private var didAttemptResume = false

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

    /// Opens the most recent cached scan, if any, instead of starting at the picker: the
    /// tree appears immediately (marked with its scan date) and a background rescan starts
    /// to bring it up to date. Called once when the UI appears; no-op without a cache.
    func attemptResume() {
        guard !didAttemptResume else { return }
        didAttemptResume = true
        guard phase == .idle, root == nil else { return }

        let store = snapshotStore
        Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                () -> (entry: SnapshotStore.Entry, tree: FileNode)? in
                guard let entry = store.mostRecent(),
                      let tree = try? store.loadTree(entry) else { return nil }
                return (entry, tree)
            }.value
            guard let self, let loaded, self.phase == .idle, self.root == nil else { return }

            self.root = loaded.tree
            self.lastScanDate = loaded.entry.header.scanDate
            self.setFocus(loaded.tree)
            self.phase = .result
            self.recountUnreadable(in: loaded.tree)
            self.classify(loaded.tree)
            self.startBackgroundRefresh(
                at: URL(fileURLWithPath: loaded.entry.header.rootPath),
                expectedBytes: loaded.entry.header.totalBytes
            )
        }
    }

    func startScan(at url: URL) {
        cancelScan()
        cancelRefresh()
        classifyTask?.cancel()
        phase = .scanning
        scanActive = true
        liveScan = nil
        progress = ScanProgress(itemsScanned: 0, bytesAccumulated: 0, currentPath: url.path)
        root = nil
        focus = nil
        segments = []
        rows = []
        focusDisplayTotal = 0
        pendingTrash = nil
        errorMessage = nil
        unreadableCount = 0

        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await update in self.scanner.scan(at: url) {
                    switch update {
                    case .started(let handle):
                        self.liveScan = handle
                    case .progress(let progress):
                        self.progress = progress
                    case .partial(let snapshot):
                        self.adoptPartialTree(snapshot)
                    case .finished(let tree):
                        self.scanActive = false
                        self.liveScan = nil
                        self.adoptFinishedTree(tree)
                    }
                }
            } catch is CancellationError {
                self.scanActive = false
                self.liveScan = nil
                self.phase = .idle
            } catch {
                self.scanActive = false
                self.liveScan = nil
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
        cancelRefresh()
        layoutTask?.cancel()
        layoutTask = nil
        classifyTask?.cancel()
        classifyTask = nil
        scanActive = false
        liveScan = nil
        lastScanDate = nil
        phase = .idle
        root = nil
        focus = nil
        segments = []
        rows = []
        focusDisplayTotal = 0
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
        // Steer the running scan's partial snapshots to follow the user's focus. No-op when no
        // scan is live (`liveScan` nil for cache-loaded/background-refreshed trees).
        liveScan?.focusPath = TreePath.components(of: node)
        rebuild(for: node)
    }

    /// Recomputes the sunburst segments, the panel rows, and the focus's display total for
    /// `node` in the current mode, off the main thread.
    private func rebuild(for node: FileNode) {
        layoutTask?.cancel()
        let mode = displayMode
        layoutTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                () -> (segments: [SunburstSegment], rows: [ContentsPanelRow], total: Int64) in
                let segments = SunburstLayout.build(focus: node, mode: mode)
                let rows = SunburstLayout.rows(focus: node, mode: mode)
                let total = SunburstLayout.focusDisplayTotal(focus: node, mode: mode)
                return (segments, rows, total)
            }.value
            guard !Task.isCancelled else { return }
            self?.segments = result.segments
            self?.rows = result.rows
            self?.focusDisplayTotal = result.total
        }
    }

    /// Adopts a live partial `snapshot` as the on-screen tree so the user can browse the scan
    /// as it grows. Mirrors `adoptRefreshedTree`'s focus-by-path restoration but skips the
    /// finish work (classification, unreadable recount, snapshot save, `lastScanDate`): partial
    /// sizes are growing lower bounds and carry no dev classification. On the first partial it
    /// flips `phase` to `.result`, replacing the transient scanning screen with the browser.
    private func adoptPartialTree(_ snapshot: FileNode) {
        let focusComponents = focus.map { TreePath.components(of: $0) } ?? []
        root = snapshot
        setFocus(TreePath.resolve(focusComponents, in: snapshot))
        if phase != .result {
            phase = .result
        }
    }

    /// Adopts the final, fully aggregated tree from `.finished`, restoring the focus by path so a
    /// user who navigated during the scan is not yanked back to the root. Runs the finish work
    /// partials skip.
    private func adoptFinishedTree(_ tree: FileNode) {
        let focusComponents = focus.map { TreePath.components(of: $0) } ?? []
        root = tree
        setFocus(TreePath.resolve(focusComponents, in: tree))
        phase = .result
        lastScanDate = Date()
        recountUnreadable(in: tree)
        classify(tree)
        saveSnapshot(of: tree)
    }

    /// Classifies the tree against the dev-item catalog off the main thread, then rebuilds if
    /// the current mode depends on the result. Mirrors `recountUnreadable`'s cancel-and-replace
    /// pattern: a later trash may mutate the tree, so an in-flight pass is cancelled and reissued
    /// on the mutated tree rather than serialized against it.
    private func classify(_ tree: FileNode) {
        classifyTask?.cancel()
        let catalog = catalog
        classifyTask = Task { [weak self] in
            await Task.detached(priority: .utility) {
                DevClassifier.classify(tree, using: catalog)
            }.value
            guard !Task.isCancelled, let self else { return }
            if self.displayMode != .all, let focus = self.focus {
                self.rebuild(for: focus)
            }
        }
    }

    // MARK: - Background refresh & snapshots

    /// Rescans `url` while the cache-loaded tree stays on screen, then swaps the fresh tree
    /// in, restoring the focus to the same path (or its nearest surviving ancestor).
    private func startBackgroundRefresh(at url: URL, expectedBytes: Int64) {
        cancelRefresh()
        expectedRefreshBytes = expectedBytes
        refreshProgress = ScanProgress(itemsScanned: 0, bytesAccumulated: 0, currentPath: url.path)

        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await update in self.scanner.scan(at: url) {
                    switch update {
                    case .started:
                        break  // Stage 5 wires the focus handle here.
                    case .progress(let progress):
                        self.refreshProgress = progress
                    case .partial:
                        break  // Stage 3 will render live partial snapshots here.
                    case .finished(let tree):
                        self.adoptRefreshedTree(tree)
                    }
                }
            } catch is CancellationError {
                self.refreshProgress = nil
            } catch {
                // The cached root may be gone (unmounted disk, deleted folder). The stale
                // tree on screen would be pure fiction at this point — return to the picker.
                self.refreshProgress = nil
                self.returnToStart()
            }
        }
    }

    private func adoptRefreshedTree(_ tree: FileNode) {
        let focusComponents = focus.map { TreePath.components(of: $0) } ?? []
        root = tree
        setFocus(TreePath.resolve(focusComponents, in: tree))
        lastScanDate = Date()
        refreshProgress = nil
        recountUnreadable(in: tree)
        classify(tree)
        saveSnapshot(of: tree)
    }

    private func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshProgress = nil
        expectedRefreshBytes = 0
    }

    /// Serializes the tree to the snapshot cache off the main thread. Cancel-and-replace,
    /// like the classify pass: a newer save supersedes an in-flight one. Failures are
    /// swallowed — the cache is an optimization, never a source of errors.
    private func saveSnapshot(of tree: FileNode) {
        snapshotSaveTask?.cancel()
        let store = snapshotStore
        let date = lastScanDate ?? Date()
        snapshotSaveTask = Task {
            await Task.detached(priority: .utility) {
                try? store.save(tree, scanDate: date)
            }.value
        }
    }

    // MARK: - Deletion

    func reveal(_ node: FileNode) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
    }

    func requestTrash(_ node: FileNode) {
        // Partial-scan sizes are lower bounds and the tree is still mutating; acting on it
        // invites deleting the wrong thing. The UI also hides the affordance (see ContentsPanel).
        guard !scanActive else { return }
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
            if let root {
                recountUnreadable(in: root)
                // Re-classify: deleting inside a dev root leaves ancestor devSize stale, and
                // deleting a guard file (e.g. Cargo.toml) can change which nodes match.
                classify(root)
                saveSnapshot(of: root)
            }
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
