import Darwin
import Foundation
import Synchronization

/// Drives a parallel, single-volume disk scan and builds the `FileNode` tree.
///
/// A fixed pool of workers shares a FIFO queue of directories still to enumerate (an array
/// consumed from a head index), so the tree is walked breadth-first and shallow levels
/// stabilize first. Each worker opens a directory, enumerates it with `getattrlistbulk(2)`,
/// publishes its child nodes to that directory, and pushes any subdirectories back onto the
/// queue. Termination is detected when every worker is simultaneously idle with no queued
/// jobs. Directory sizes grow as live partial sums during the scan and are recomputed exactly
/// by a post-order pass after enumeration completes.
final class ScanCoordinator: @unchecked Sendable {
    private struct Job {
        let node: FileNode
        let path: String
    }

    private struct HardLinkKey: Hashable {
        let device: dev_t
        let fileID: UInt64
    }

    private let workerCount: Int
    private let rootDevice: dev_t
    private let root: FileNode

    /// Guards `stack`, `stackHead`, `idleWorkers`, and `isFinished`.
    private let condition = NSCondition()
    /// Jobs are appended to the end and consumed from `stackHead` (FIFO / breadth-first); the
    /// consumed prefix is compacted away once it exceeds half the array to keep this O(1).
    private var stack: [Job] = []
    private var stackHead = 0
    private var idleWorkers = 0
    private var isFinished = false

    /// Guards every read/write of a *published* node's `children`, the bubbling of directory
    /// `allocatedSize` up the parent chain, `isUnreadable` on already-published nodes, and the
    /// final aggregation. `partialSnapshot` reads the live tree under this same lock. Taken once
    /// per directory (at publication), never per file entry, to keep the hot path lean.
    private let treeLock = Mutex<Void>(())

    /// Read on the hot path without taking `condition`; set by `cancel()`.
    private let cancelled = Atomic<Bool>(false)

    private let itemsScanned = Atomic<Int>(0)
    private let bytesAccumulated = Atomic<Int64>(0)
    private let hardLinks = Mutex<Set<HardLinkKey>>([])
    private let currentPath = Mutex<String>("")

    private static let bufferSize = 256 * 1024

    init(root url: URL, workerCount: Int) throws {
        let rootPath = url.standardizedFileURL.path
        var status = stat()
        guard stat(rootPath, &status) == 0 else {
            throw ScanError.cannotAccessRoot(path: rootPath, errno: errno)
        }
        self.workerCount = max(1, workerCount)
        self.rootDevice = status.st_dev
        self.root = FileNode(name: rootPath, isDirectory: true, parent: nil)
    }

    // MARK: - Public control

    func cancel() {
        cancelled.store(true, ordering: .relaxed)
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    func snapshotProgress() -> ScanProgress {
        ScanProgress(
            itemsScanned: itemsScanned.load(ordering: .relaxed),
            bytesAccumulated: bytesAccumulated.load(ordering: .relaxed),
            currentPath: currentPath.withLock { $0 }
        )
    }

    /// Runs the scan to completion (or cancellation) and returns the aggregated tree.
    /// Throws `CancellationError` if cancelled.
    func run() throws -> FileNode {
        condition.lock()
        stack.append(Job(node: root, path: root.name))
        condition.unlock()

        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "org.cosmoshark.DiscFree.scan.workers",
            qos: .userInitiated,
            attributes: .concurrent
        )
        for _ in 0..<workerCount {
            group.enter()
            queue.async {
                self.workerLoop()
                group.leave()
            }
        }
        group.wait()

        if cancelled.load(ordering: .relaxed) {
            throw CancellationError()
        }

        // Serialize against any in-flight `partialSnapshot` reader: aggregation overwrites the
        // live partial sizes, and workers are done, so this is uncontended except for snapshots.
        treeLock.withLock { _ in _ = aggregate(root) }
        return root
    }

    // MARK: - Cloud-eviction (dataless) policy

    // iCloud / File Provider directories can be *dataless* (evicted): their contents live in
    // the cloud, not on local disk. Opening such a directory with `open(2)` makes
    // fileproviderd materialize (download) the whole package, blocking the call for minutes
    // or forever. With VFS materialization disabled on the calling thread, `open(2)` instead
    // fails fast with `EDEADLK`, which the scanner treats as unreadable (correct for a
    // disk-space analyzer: evicted content occupies no local disk space). The policy is
    // per-thread and GCD worker threads are reused, so callers MUST restore the previous
    // value once done.

    /// Disables materialization of dataless files on the current thread and returns the
    /// previous policy value, so it can be handed back to `restoreDatalessMaterialization`.
    static func disableDatalessMaterialization() -> Int32 {
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        setiopolicy_np(
            IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
            IOPOL_SCOPE_THREAD,
            IOPOL_MATERIALIZE_DATALESS_FILES_OFF
        )
        return previous
    }

    /// Restores a previously captured dataless-materialization policy on the current thread.
    static func restoreDatalessMaterialization(_ previous: Int32) {
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous)
    }

    // MARK: - Worker pool

    private func workerLoop() {
        // Disable cloud-eviction materialization for this worker thread so `open(2)` on a
        // dataless (evicted) directory fails fast with EDEADLK instead of blocking on a
        // fileproviderd download. GCD threads outlive the scan and get reused, so restore.
        let previousDatalessPolicy = Self.disableDatalessMaterialization()
        defer { Self.restoreDatalessMaterialization(previousDatalessPolicy) }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        condition.lock()
        while true {
            if cancelled.load(ordering: .relaxed) {
                condition.unlock()
                return
            }

            if stackHead < stack.count {
                let job = stack[stackHead]
                stackHead += 1
                // Compact the consumed prefix once it exceeds half the array (amortized O(1)).
                if stackHead > stack.count / 2 {
                    stack.removeFirst(stackHead)
                    stackHead = 0
                }
                condition.unlock()
                let subdirectories = process(job, buffer: buffer)
                condition.lock()
                if !subdirectories.isEmpty {
                    stack.append(contentsOf: subdirectories)
                    condition.broadcast()
                }
                continue
            }

            // No work available right now.
            idleWorkers += 1
            if idleWorkers == workerCount {
                // Every worker is idle and the queue is empty: the scan is done.
                isFinished = true
                condition.broadcast()
                condition.unlock()
                return
            }
            while stackHead >= stack.count && !isFinished && !cancelled.load(ordering: .relaxed) {
                condition.wait()
            }
            idleWorkers -= 1
            if isFinished || cancelled.load(ordering: .relaxed) {
                condition.unlock()
                return
            }
        }
    }

    // MARK: - Directory enumeration

    /// Enumerates one directory, populating `job.node.children` and returning its subdirectories.
    private func process(_ job: Job, buffer: UnsafeMutableRawPointer) -> [Job] {
        currentPath.withLock { $0 = job.path }

        let fd = open(job.path, O_RDONLY | O_DIRECTORY)
        if fd < 0 {
            // Cloud-evicted (dataless) directories fail here with EDEADLK (materialization is
            // disabled per worker thread) and intentionally land in this unreadable branch.
            // The node is already published in its parent's children, so guard the write.
            treeLock.withLock { _ in job.node.isUnreadable = true }
            return []
        }
        defer { close(fd) }

        var attrList = BulkDirectoryReader.makeAttrList()
        var subdirectories: [Job] = []
        // Children accumulate locally and are published with one assignment under the tree lock
        // when enumeration of this directory completes, so snapshot readers never see a partially
        // filled array.
        var localChildren: [FileNode] = []
        var items = 0
        var bytes: Int64 = 0

        while true {
            if cancelled.load(ordering: .relaxed) { break }

            let count = getattrlistbulk(fd, &attrList, buffer, Self.bufferSize, 0)
            if count <= 0 { break }  // 0 = no more entries, -1 = error

            var pointer = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let entry = BulkDirectoryReader.parse(pointer)
                if entry.recordLength <= 0 { break }
                defer { pointer = pointer.advanced(by: entry.recordLength) }

                items += 1

                // Per-entry error: keep a flagged placeholder and move on. Safe to mutate before
                // publication (this node is not yet visible to snapshot readers).
                if entry.error != 0 {
                    if entry.hasName {
                        let node = FileNode(name: entry.name, isDirectory: false, parent: job.node)
                        node.isUnreadable = true
                        localChildren.append(node)
                    }
                    continue
                }

                guard entry.hasName, entry.name != ".", entry.name != ".." else { continue }

                // Do not cross device boundaries (mount points, other volumes).
                if entry.hasDevID, entry.devID != rootDevice { continue }

                switch entry.objType {
                case UInt32(VDIR.rawValue):
                    let node = FileNode(name: entry.name, isDirectory: true, parent: job.node)
                    localChildren.append(node)
                    subdirectories.append(
                        Job(node: node, path: Self.appending(entry.name, to: job.path))
                    )

                case UInt32(VLNK.rawValue):
                    // Symlinks are not followed; counted by their own size.
                    let size = entry.hasAllocatedSize ? entry.allocatedSize : 0
                    let node = FileNode(
                        name: entry.name, isDirectory: false, allocatedSize: size, parent: job.node
                    )
                    localChildren.append(node)
                    bytes += size

                default:
                    // Regular files (and other leaf objects): count own allocated size,
                    // deduplicating hard links so shared inodes are counted once.
                    var size = entry.hasAllocatedSize ? entry.allocatedSize : 0
                    if entry.hasLinkCount, entry.linkCount > 1, entry.hasFileID {
                        let key = HardLinkKey(device: entry.devID, fileID: entry.fileID)
                        let inserted = hardLinks.withLock { $0.insert(key).inserted }
                        if !inserted { size = 0 }
                    }
                    let node = FileNode(
                        name: entry.name, isDirectory: false, allocatedSize: size, parent: job.node
                    )
                    localChildren.append(node)
                    bytes += size
                }
            }
        }

        // Publish children with a single assignment and bubble this directory's direct-file bytes
        // up the parent chain to the root, both under the tree lock. The bubble gives every
        // ancestor a monotonically growing partial size as more directories complete.
        treeLock.withLock { _ in
            job.node.children = localChildren
            if bytes > 0 {
                var node: FileNode? = job.node
                while let current = node {
                    current.allocatedSize += bytes
                    node = current.parent
                }
            }
        }

        if items > 0 { itemsScanned.wrappingAdd(items, ordering: .relaxed) }
        if bytes > 0 { bytesAccumulated.wrappingAdd(bytes, ordering: .relaxed) }
        return subdirectories
    }

    // MARK: - Partial snapshots

    /// Returns a detached copy of the in-progress tree, following the UI's current focus.
    ///
    /// Resolves `focusPath` from the root by matching child names level by level, stopping at the
    /// deepest node that still exists (same fallback as `TreePath.resolve`: a component may be
    /// missing because that area is not yet scanned or a partial cap hid it — the deepest resolved
    /// node becomes the effective focus). The chain from the root down to that effective focus is
    /// always copied in full: at each chain level the node's `topChildren` largest children are
    /// copied too, always including the chain child so the chain never dangles. From the effective
    /// focus, descendants are copied largest-first, `maxDepth` levels below the focus, `topChildren`
    /// per directory; the chain above the focus does NOT count against `maxDepth`. Every copied node
    /// counts against `nodeBudget`, but the resolved chain is copied even when the budget is
    /// exhausted, so a snapshot never lacks its focus chain.
    ///
    /// `focusPath: []` reduces to a root-anchored snapshot. Every copy is a fresh `FileNode` with
    /// `parent` links wired within the copy; `allocatedSize` carries the current partial lower bound
    /// and `isUnreadable` is preserved (dev-classification fields are left at their defaults). Never
    /// reads `FileNode.path` (an O(depth) rebuild).
    func partialSnapshot(
        focusPath: [String], maxDepth: Int, topChildren: Int, nodeBudget: Int
    ) -> FileNode {
        treeLock.withLock { _ in
            var budget = nodeBudget
            return copyFocusChain(
                root, parent: nil, focusPath: focusPath[...],
                maxDepth: maxDepth, topChildren: topChildren, budget: &budget
            )
        }
    }

    /// Copies `node` and continues toward the focus. If `focusPath` still names an existing child,
    /// `node` is an ancestor on the chain: it is copied along with its `topChildren` largest
    /// children (always including that chain child, so the chain never dangles), and only the chain
    /// child recurses with the remaining path; the other selected siblings are copied shallowly.
    /// Otherwise the path is exhausted or the next component is missing, so `node` is the effective
    /// focus and its descendants are copied via `copySubtree` (depth 0). The chain is copied even
    /// when `budget` is exhausted; only the shallow non-chain siblings are dropped once the budget
    /// runs out. Must be called with `treeLock` held.
    private func copyFocusChain(
        _ node: FileNode,
        parent: FileNode?,
        focusPath: ArraySlice<String>,
        maxDepth: Int,
        topChildren: Int,
        budget: inout Int
    ) -> FileNode {
        guard let name = focusPath.first,
              let children = node.children,
              let chainChild = children.first(where: { $0.name == name })
        else {
            return copySubtree(
                node, parent: parent, depth: 0,
                maxDepth: maxDepth, topChildren: topChildren, budget: &budget
            )
        }

        let copy = FileNode(
            name: node.name,
            isDirectory: node.isDirectory,
            allocatedSize: node.allocatedSize,
            parent: parent
        )
        copy.isUnreadable = node.isUnreadable
        budget -= 1

        // Largest-first, capped at `topChildren`, with the chain child forced in even if it did
        // not make the cut, then re-sorted so the selection stays in descending-size order.
        var selected = children.sorted { $0.allocatedSize > $1.allocatedSize }
        if selected.count > topChildren { selected = Array(selected.prefix(topChildren)) }
        if !selected.contains(where: { $0 === chainChild }) {
            selected.append(chainChild)
            selected.sort { $0.allocatedSize > $1.allocatedSize }
        }

        let remaining = focusPath.dropFirst()
        var copiedChildren: [FileNode] = []
        for child in selected {
            if child === chainChild {
                // Always recurse the chain, regardless of the remaining budget.
                copiedChildren.append(
                    copyFocusChain(
                        child, parent: copy, focusPath: remaining,
                        maxDepth: maxDepth, topChildren: topChildren, budget: &budget
                    )
                )
            } else {
                if budget <= 0 { continue }
                copiedChildren.append(copyShallow(child, parent: copy, budget: &budget))
            }
        }
        copy.children = copiedChildren
        return copy
    }

    /// Copies a single node without its descendants; a directory keeps an empty `children` array,
    /// matching how `copySubtree` leaves a directory copied at `maxDepth`. Used for the non-chain
    /// siblings alongside the focus chain. Must be called with `treeLock` held.
    private func copyShallow(_ node: FileNode, parent: FileNode?, budget: inout Int) -> FileNode {
        let copy = FileNode(
            name: node.name,
            isDirectory: node.isDirectory,
            allocatedSize: node.allocatedSize,
            parent: parent
        )
        copy.isUnreadable = node.isUnreadable
        budget -= 1
        return copy
    }

    /// Copies `node` and — if it is a directory below `maxDepth` — its largest-first children,
    /// decrementing `budget` per copied node. Must be called with `treeLock` held.
    private func copySubtree(
        _ node: FileNode,
        parent: FileNode?,
        depth: Int,
        maxDepth: Int,
        topChildren: Int,
        budget: inout Int
    ) -> FileNode {
        let copy = FileNode(
            name: node.name,
            isDirectory: node.isDirectory,
            allocatedSize: node.allocatedSize,
            parent: parent
        )
        copy.isUnreadable = node.isUnreadable
        budget -= 1

        guard node.isDirectory, depth < maxDepth,
              let children = node.children, !children.isEmpty
        else { return copy }

        // Largest-first, capped at `topChildren`.
        let ordered = children.sorted { $0.allocatedSize > $1.allocatedSize }
        let selected = ordered.count > topChildren ? Array(ordered.prefix(topChildren)) : ordered

        var copiedChildren: [FileNode] = []
        for child in selected {
            if budget <= 0 { break }
            copiedChildren.append(
                copySubtree(
                    child, parent: copy, depth: depth + 1,
                    maxDepth: maxDepth, topChildren: topChildren, budget: &budget
                )
            )
        }
        copy.children = copiedChildren
        return copy
    }

    // MARK: - Aggregation

    /// Post-order sum: a directory's size is the total of its descendants (files only). This runs
    /// after all workers finish and overwrites the live partial sums accumulated during the scan
    /// with exact totals; it is authoritative.
    @discardableResult
    private func aggregate(_ node: FileNode) -> Int64 {
        guard let children = node.children else { return node.allocatedSize }
        var total: Int64 = 0
        for child in children {
            total += aggregate(child)
        }
        node.allocatedSize = total
        return total
    }

    private static func appending(_ name: String, to base: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }
}
