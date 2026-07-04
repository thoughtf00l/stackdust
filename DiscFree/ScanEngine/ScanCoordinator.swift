import Darwin
import Foundation
import Synchronization

/// Drives a parallel, single-volume disk scan and builds the `FileNode` tree.
///
/// A fixed pool of workers shares a LIFO stack of directories still to enumerate. Each
/// worker opens a directory, enumerates it with `getattrlistbulk(2)`, appends child nodes
/// to that directory, and pushes any subdirectories back onto the stack. Termination is
/// detected when every worker is simultaneously idle with an empty stack. Directory sizes
/// are summed in a post-order pass after enumeration completes.
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

    /// Guards `stack`, `idleWorkers`, and `isFinished`.
    private let condition = NSCondition()
    private var stack: [Job] = []
    private var idleWorkers = 0
    private var isFinished = false

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

        aggregate(root)
        return root
    }

    // MARK: - Worker pool

    private func workerLoop() {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        condition.lock()
        while true {
            if cancelled.load(ordering: .relaxed) {
                condition.unlock()
                return
            }

            if let job = stack.popLast() {
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
                // Every worker is idle and the stack is empty: the scan is done.
                isFinished = true
                condition.broadcast()
                condition.unlock()
                return
            }
            while stack.isEmpty && !isFinished && !cancelled.load(ordering: .relaxed) {
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
            job.node.isUnreadable = true
            return []
        }
        defer { close(fd) }

        var attrList = BulkDirectoryReader.makeAttrList()
        var subdirectories: [Job] = []
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

                // Per-entry error: keep a flagged placeholder and move on.
                if entry.error != 0 {
                    if entry.hasName {
                        let node = FileNode(name: entry.name, isDirectory: false, parent: job.node)
                        node.isUnreadable = true
                        job.node.children?.append(node)
                    }
                    continue
                }

                guard entry.hasName, entry.name != ".", entry.name != ".." else { continue }

                // Do not cross device boundaries (mount points, other volumes).
                if entry.hasDevID, entry.devID != rootDevice { continue }

                switch entry.objType {
                case UInt32(VDIR.rawValue):
                    let node = FileNode(name: entry.name, isDirectory: true, parent: job.node)
                    job.node.children?.append(node)
                    subdirectories.append(
                        Job(node: node, path: Self.appending(entry.name, to: job.path))
                    )

                case UInt32(VLNK.rawValue):
                    // Symlinks are not followed; counted by their own size.
                    let size = entry.hasAllocatedSize ? entry.allocatedSize : 0
                    let node = FileNode(
                        name: entry.name, isDirectory: false, allocatedSize: size, parent: job.node
                    )
                    job.node.children?.append(node)
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
                    job.node.children?.append(node)
                    bytes += size
                }
            }
        }

        if items > 0 { itemsScanned.wrappingAdd(items, ordering: .relaxed) }
        if bytes > 0 { bytesAccumulated.wrappingAdd(bytes, ordering: .relaxed) }
        return subdirectories
    }

    // MARK: - Aggregation

    /// Post-order sum: a directory's size is the total of its descendants (files only).
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
