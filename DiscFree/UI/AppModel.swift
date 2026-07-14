import SwiftUI
import Observation
import AppKit
import DiscFreeCore

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

    /// The focus node's direct children as panel rows.
    private(set) var rows: [ContentsPanelRow] = []

    /// The current focus's `allocatedSize`. Drives share bars, the center label, and the status.
    private(set) var focusDisplayTotal: Int64 = 0

    /// Whether the sunburst tints each segment by its reclaimable share instead of drawing full
    /// branch colors. Toggling it recomputes the layout for the current focus.
    var highlightReclaimable: Bool = false {
        didSet {
            guard highlightReclaimable != oldValue, let focus else { return }
            rebuild(for: focus)
        }
    }

    /// Current focus (center of the sunburst). Changing it recomputes the layout.
    private(set) var focus: FileNode?

    /// Node awaiting a Move-to-Trash confirmation; non-nil drives the confirmation dialog.
    private(set) var pendingTrash: FileNode?
    /// Last deletion error; non-nil drives the error alert.
    private(set) var errorMessage: String?

    // MARK: - Reclaim pane state

    /// Whether the Reclaim sheet is presented over the result view. Plain view state; does not
    /// touch the tree.
    var reclaimPresented: Bool = false

    /// Category-first reclaimable items for the current root, recomputed off the main thread at the
    /// end of each classification pass. Empty during a scan and until the first classify completes.
    private(set) var reclaimGroups: [ReclaimGroup] = []

    /// Friendly display labels for reclaim items whose path is otherwise opaque — the
    /// simulator/emulator device directories (an opaque UUID for CoreSimulator, `<name>.avd` for
    /// Android). Keyed by node identity, built off the main thread alongside `reclaimGroups` and
    /// replaced atomically with it. Items absent from the map fall back to their relative path.
    private(set) var reclaimLabels: [ObjectIdentifier: String] = [:]

    /// Identities (by node) of the reclaim items the user has checked for batch trashing. Pruned to
    /// the ids still present whenever `reclaimGroups` recomputes.
    private(set) var reclaimSelection: Set<ObjectIdentifier> = []

    /// Set by `requestReclaimTrash`; non-nil drives the reclaim confirmation dialog.
    private(set) var pendingReclaimTrash: PendingReclaimTrash?

    /// The summary a reclaim confirmation dialog presents.
    struct PendingReclaimTrash {
        let count: Int
        let bytes: Int64
        /// True when any selected item loses non-regenerable state; adds a warning line.
        let warnsLosesState: Bool
    }

    /// Whether the app can read protected locations; drives the Full Disk Access hint.
    private(set) var fullDiskAccess: FullDiskAccessStatus = .undetermined
    /// Number of unreadable directories (genuine read failures) across the whole scanned tree.
    /// Computed off the main thread once per scan and after each deletion — never walked per frame.
    private(set) var unreadableCount: Int = 0
    /// Number of iCloud-evicted (dataless) directories across the whole scanned tree, counted in
    /// the same off-main-thread walk as `unreadableCount`. Excluded from `unreadableCount`.
    private(set) var cloudEvictedCount: Int = 0

    /// Free space on the volume holding the scan root, including purgeable space (the figure
    /// Finder reports, via `volumeAvailableCapacityForImportantUsage`). Nil when unreadable.
    /// Refreshed at scan start, on each tree adoption, and after every successful trash — reading
    /// one resource value is cheap, so no timer.
    private(set) var freeSpaceBytes: Int64?

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
    private var reclaimTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var snapshotSaveTask: Task<Void, Never>?
    private var didAttemptResume = false
    /// URL of the current scan root, kept so free space can be re-read after a trash (which has
    /// no URL in hand) without re-deriving it from the tree.
    private var scanRootURL: URL?

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

            let rootURL = URL(fileURLWithPath: loaded.entry.header.rootPath)
            self.scanRootURL = rootURL
            self.refreshFreeSpace()
            self.root = loaded.tree
            self.lastScanDate = loaded.entry.header.scanDate
            self.setFocus(loaded.tree)
            self.phase = .result
            self.recountUnreadable(in: loaded.tree)
            self.classify(loaded.tree)
            self.startBackgroundRefresh(
                at: rootURL,
                expectedBytes: loaded.entry.header.totalBytes
            )
        }
    }

    func startScan(at url: URL) {
        cancelScan()
        cancelRefresh()
        classifyTask?.cancel()
        reclaimTask?.cancel()
        phase = .scanning
        scanActive = true
        liveScan = nil
        scanRootURL = url
        refreshFreeSpace()
        progress = ScanProgress(itemsScanned: 0, bytesAccumulated: 0, currentPath: url.path)
        root = nil
        focus = nil
        segments = []
        rows = []
        focusDisplayTotal = 0
        pendingTrash = nil
        errorMessage = nil
        unreadableCount = 0
        cloudEvictedCount = 0
        reclaimGroups = []
        reclaimLabels = [:]
        reclaimSelection = []
        pendingReclaimTrash = nil

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
        reclaimTask?.cancel()
        reclaimTask = nil
        scanActive = false
        liveScan = nil
        lastScanDate = nil
        scanRootURL = nil
        freeSpaceBytes = nil
        phase = .idle
        root = nil
        focus = nil
        segments = []
        rows = []
        focusDisplayTotal = 0
        pendingTrash = nil
        errorMessage = nil
        unreadableCount = 0
        cloudEvictedCount = 0
        reclaimGroups = []
        reclaimLabels = [:]
        reclaimSelection = []
        pendingReclaimTrash = nil
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
    /// `node`, off the main thread.
    private func rebuild(for node: FileNode) {
        layoutTask?.cancel()
        let highlight = highlightReclaimable
        layoutTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                () -> (segments: [SunburstSegment], rows: [ContentsPanelRow], total: Int64) in
                let segments = SunburstLayout.build(focus: node, highlight: highlight)
                let rows = SunburstLayout.rows(focus: node, highlight: highlight)
                let total = SunburstLayout.focusDisplayTotal(focus: node)
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
        refreshFreeSpace()
        recountUnreadable(in: tree)
        classify(tree)
        saveSnapshot(of: tree)
    }

    /// Classifies the tree against the dev-item catalog off the main thread, then rebuilds when
    /// highlighting is on (the segment tints depend on the classification). Mirrors
    /// `recountUnreadable`'s cancel-and-replace pattern: a later trash may mutate the tree, so an
    /// in-flight pass is cancelled and reissued on the mutated tree rather than serialized
    /// against it.
    private func classify(_ tree: FileNode) {
        classifyTask?.cancel()
        let catalog = catalog
        classifyTask = Task { [weak self] in
            await Task.detached(priority: .utility) {
                DevClassifier.classify(tree, using: catalog)
            }.value
            guard !Task.isCancelled, let self else { return }
            if self.highlightReclaimable, let focus = self.focus {
                self.rebuild(for: focus)
            }
            // Classification is the data source for the reclaim summary: every finish/adopt/trash
            // path re-runs classify, so chaining the recompute here keeps the two in step.
            self.recomputeReclaimGroups(from: tree)
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
        refreshFreeSpace()
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
            refreshFreeSpace()
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

    // MARK: - Reclaim pane

    /// Rebuilds `reclaimGroups` from `tree` off the main thread (cancel-and-replace, like
    /// `classify` and `recountUnreadable`), then prunes the selection to the items that still
    /// exist. Chained off each classification pass, which is its data source.
    private func recomputeReclaimGroups(from tree: FileNode) {
        reclaimTask?.cancel()
        reclaimTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                () -> (groups: [ReclaimGroup], labels: [ObjectIdentifier: String]) in
                let groups = ReclaimSummary.build(from: tree)
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let labels = Self.reclaimDeviceLabels(for: groups, home: home)
                return (groups, labels)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.reclaimGroups = result.groups
            self.reclaimLabels = result.labels
            self.pruneReclaimSelection()
        }
    }

    /// Friendly labels for reclaim items whose directory names are otherwise opaque: the
    /// simulator/emulator devices and the per-device/OS-version device-support folders. Runs off
    /// the main thread inside the reclaim recompute. Only the simulator branch touches the disk —
    /// it reads each CoreSimulator device's `device.plist`, bounded to a few dozen devices; the
    /// device-support branch derives its label entirely from the folder name (no disk access).
    private nonisolated static func reclaimDeviceLabels(
        for groups: [ReclaimGroup],
        home: String
    ) -> [ObjectIdentifier: String] {
        let coreSimulatorDevices = "\(home)/Library/Developer/CoreSimulator/Devices"
        let androidAvd = "\(home)/.android/avd"
        var labels: [ObjectIdentifier: String] = [:]
        for group in groups {
            switch group.category {
            case .simulators:
                for item in group.items {
                    let parent = (item.path as NSString).deletingLastPathComponent
                    if parent == coreSimulatorDevices {
                        if let label = coreSimulatorLabel(devicePath: item.path) {
                            labels[ObjectIdentifier(item.node)] = label
                        }
                    } else if parent == androidAvd {
                        let name = (item.path as NSString).lastPathComponent
                        let stripped = name.hasSuffix(".avd") ? String(name.dropLast(4)) : name
                        if !stripped.isEmpty {
                            labels[ObjectIdentifier(item.node)] = stripped
                        }
                    }
                }
            case .deviceSupport:
                // The child dir name (e.g. "iPhone14,2 15.0 (19A346)") carries the device and OS
                // version; the platform word comes from the parent "<platform> DeviceSupport" dir.
                for item in group.items {
                    let parentName = ((item.path as NSString).deletingLastPathComponent as NSString)
                        .lastPathComponent
                    guard parentName.hasSuffix(" DeviceSupport") else { continue }
                    let platform = String(parentName.dropLast(" DeviceSupport".count))
                    let childName = (item.path as NSString).lastPathComponent
                    labels[ObjectIdentifier(item.node)] =
                        AppleDeviceNames.deviceSupportLabel(childName: childName, platform: platform)
                }
            default:
                break
            }
        }
        return labels
    }

    /// Reads a CoreSimulator device's `device.plist` and formats "<name> (<runtime>)", e.g.
    /// "iPhone 16 Pro (iOS 18.2)". Falls back to the name alone when the runtime is missing or
    /// unparseable, and to `nil` (the view then shows the path) when even the name is absent.
    private nonisolated static func coreSimulatorLabel(devicePath: String) -> String? {
        guard let dict = NSDictionary(contentsOfFile: "\(devicePath)/device.plist"),
              let name = (dict["name"] as? String), !name.isEmpty else { return nil }
        guard let runtime = dict["runtime"] as? String,
              let human = humanRuntime(runtime) else { return name }
        return "\(name) (\(human))"
    }

    /// Turns a CoreSimulator runtime identifier into a human string: takes the component after the
    /// last `.SimRuntime.` (`com.apple.CoreSimulator.SimRuntime.iOS-18-2` → `iOS-18-2`), then splits
    /// on `-` — first part is the platform, the rest joins with `.` as the version → "iOS 18.2".
    /// Returns nil when there is no `.SimRuntime.` marker or no version component.
    private nonisolated static func humanRuntime(_ runtime: String) -> String? {
        guard let marker = runtime.range(of: ".SimRuntime.", options: .backwards) else { return nil }
        let parts = runtime[marker.upperBound...].split(separator: "-")
        guard let platform = parts.first, parts.count >= 2 else { return nil }
        return "\(platform) \(parts.dropFirst().joined(separator: "."))"
    }

    /// The friendly label for `item`, if one was built for it; otherwise nil (the view falls back
    /// to the item's relative path).
    func reclaimLabel(for item: ReclaimItem) -> String? {
        reclaimLabels[ObjectIdentifier(item.node)]
    }

    /// Drops selected ids whose nodes are no longer in `reclaimGroups` (after a rescan or a trash
    /// removed them), so the selection never references vanished items.
    private func pruneReclaimSelection() {
        let present = Set(reclaimGroups.flatMap { group in
            group.items.map { ObjectIdentifier($0.node) }
        })
        reclaimSelection.formIntersection(present)
    }

    func toggleReclaimItem(_ item: ReclaimItem) {
        let id = ObjectIdentifier(item.node)
        if reclaimSelection.contains(id) {
            reclaimSelection.remove(id)
        } else {
            reclaimSelection.insert(id)
        }
    }

    /// Selects every item in `group` if any is currently unselected; otherwise deselects them all.
    func toggleReclaimGroup(_ group: ReclaimGroup) {
        let ids = group.items.map { ObjectIdentifier($0.node) }
        if ids.allSatisfy({ reclaimSelection.contains($0) }) {
            for id in ids { reclaimSelection.remove(id) }
        } else {
            for id in ids { reclaimSelection.insert(id) }
        }
    }

    func clearReclaimSelection() {
        reclaimSelection.removeAll()
    }

    func isReclaimItemSelected(_ item: ReclaimItem) -> Bool {
        reclaimSelection.contains(ObjectIdentifier(item.node))
    }

    /// Combined size of the selected reclaim items. Cheap: group item counts are small.
    var reclaimSelectedBytes: Int64 {
        var total: Int64 = 0
        for group in reclaimGroups {
            for item in group.items where reclaimSelection.contains(ObjectIdentifier(item.node)) {
                total += item.bytes
            }
        }
        return total
    }

    var reclaimSelectedCount: Int {
        var count = 0
        for group in reclaimGroups {
            for item in group.items where reclaimSelection.contains(ObjectIdentifier(item.node)) {
                count += 1
            }
        }
        return count
    }

    func requestReclaimTrash() {
        // Same guards as the single-item flow: never act on a mutating tree, never on nothing.
        guard !scanActive else { return }
        let items = selectedReclaimItems()
        guard !items.isEmpty else { return }
        let bytes = items.reduce(0) { $0 + $1.bytes }
        let warnsLosesState = reclaimGroups.contains { group in
            group.category.riskTier == .losesState
                && group.items.contains { reclaimSelection.contains(ObjectIdentifier($0.node)) }
        }
        pendingReclaimTrash = PendingReclaimTrash(
            count: items.count, bytes: bytes, warnsLosesState: warnsLosesState
        )
    }

    func cancelReclaimTrash() {
        pendingReclaimTrash = nil
    }

    /// Moves every selected reclaim item to the Trash, then updates the tree once. The batched
    /// counterpart of `confirmTrash`: items that vanished between scan and trash are treated as
    /// already gone (still removed from the tree, matching the CLI's idempotent clean); other
    /// failures leave the node in place and are surfaced via the shared `errorMessage` alert.
    func confirmReclaimTrash() {
        pendingReclaimTrash = nil
        guard let root else { return }
        let items = selectedReclaimItems()
        guard !items.isEmpty else { return }

        // SAFETY: `TreeEditor.remove(keeping:)` rejects only the focus node itself, not an ancestor
        // of it. If the focus is a selected node or a descendant of one, detaching that node would
        // orphan the on-screen view — move focus to the root before removing anything.
        let selectedIds = Set(items.map { ObjectIdentifier($0.node) })
        if let currentFocus = focus, isFocus(currentFocus, withinSelection: selectedIds) {
            setFocus(root)
        }
        guard let focus else { return }

        let fileManager = FileManager.default
        var failures: [(path: String, message: String)] = []
        for item in items {
            var removeFromTree = false
            if !fileManager.fileExists(atPath: item.path) {
                removeFromTree = true  // already gone
            } else {
                do {
                    try fileManager.trashItem(
                        at: URL(fileURLWithPath: item.path), resultingItemURL: nil
                    )
                    removeFromTree = true
                } catch {
                    if !fileManager.fileExists(atPath: item.path) {
                        removeFromTree = true  // vanished during the attempt
                    } else {
                        failures.append((item.path, error.localizedDescription))
                    }
                }
            }
            if removeFromTree {
                // Ignore `nodeNotInTree`: an earlier removal in this batch may already have edited
                // it (e.g. a selected ancestor took a selected descendant with it).
                try? TreeEditor.remove(item.node, keeping: focus)
            }
        }

        rebuild(for: focus)
        refreshFreeSpace()
        recountUnreadable(in: root)
        classify(root)  // re-classifies and recomputes reclaimGroups
        saveSnapshot(of: root)
        clearReclaimSelection()

        if !failures.isEmpty {
            errorMessage = reclaimFailureMessage(failures)
        }
    }

    private func selectedReclaimItems() -> [ReclaimItem] {
        reclaimGroups.flatMap { group in
            group.items.filter { reclaimSelection.contains(ObjectIdentifier($0.node)) }
        }
    }

    /// True if `focus` is one of the selected nodes or a descendant of one (walks the parent chain).
    private func isFocus(_ focus: FileNode, withinSelection selected: Set<ObjectIdentifier>) -> Bool {
        var node: FileNode? = focus
        while let current = node {
            if selected.contains(ObjectIdentifier(current)) { return true }
            node = current.parent
        }
        return false
    }

    private func reclaimFailureMessage(_ failures: [(path: String, message: String)]) -> String {
        var lines = failures.prefix(3).map { "\($0.path): \($0.message)" }
        if failures.count > 3 {
            lines.append("…and \(failures.count - 3) more")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Full Disk Access

    func refreshFullDiskAccess() {
        fullDiskAccess = FullDiskAccessCheck().status()
    }

    /// Whether the app has read enough of the disk to be complete.
    var isFullDiskAccessMissing: Bool {
        fullDiskAccess == .denied
    }

    /// Re-reads the scan root volume's important-usage available capacity (the Finder figure,
    /// purgeable space included) and publishes it. Cheap enough to run inline on the main thread;
    /// degrades to nil when there is no root URL or the value can't be read.
    private func refreshFreeSpace() {
        guard let scanRootURL else {
            freeSpaceBytes = nil
            return
        }
        let values = try? scanRootURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        freeSpaceBytes = values?.volumeAvailableCapacityForImportantUsage
    }

    /// Counts unreadable and iCloud-evicted directories across the whole tree in one off-main-thread
    /// walk, publishing both figures.
    private func recountUnreadable(in tree: FileNode) {
        unreadableTask?.cancel()
        unreadableTask = Task { [weak self] in
            let counts = await Task.detached(priority: .utility) {
                Self.unreadableCounts(tree)
            }.value
            guard !Task.isCancelled else { return }
            self?.unreadableCount = counts.unreadable
            self?.cloudEvictedCount = counts.cloudEvicted
        }
    }

    /// Walks `root` once, tallying genuine read failures and iCloud-evicted directories
    /// separately (the two flags are mutually exclusive per node). Iterative so a deep tree
    /// cannot overflow the stack.
    private nonisolated static func unreadableCounts(
        _ root: FileNode
    ) -> (unreadable: Int, cloudEvicted: Int) {
        var unreadable = 0
        var cloudEvicted = 0
        var stack: [FileNode] = [root]
        while let node = stack.popLast() {
            if node.isUnreadable { unreadable += 1 }
            if node.isCloudEvicted { cloudEvicted += 1 }
            if let children = node.children { stack.append(contentsOf: children) }
        }
        return (unreadable, cloudEvicted)
    }
}
