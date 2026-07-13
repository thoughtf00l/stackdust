import XCTest
import Darwin
@testable import DiscFreeCore

final class DiskScannerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try Self.makeTempDirectory()
    }

    override func tearDownWithError() throws {
        guard let root else { return }
        // Restore permissions so the tree can be removed even if a test locked a directory.
        restorePermissions(root)
        try? FileManager.default.removeItem(at: root)
        self.root = nil
    }

    // MARK: - Aggregation over nested directories

    func testAggregatesNestedDirectories() async throws {
        // A clean tree of regular files only, so scanner (ATTR_FILE_ALLOCSIZE) and the
        // reference walk (.totalFileAllocatedSizeKey) must agree exactly.
        try writeFile(root.appendingPathComponent("a.bin"), bytes: 10_000)
        let sub1 = try makeDirectory(root.appendingPathComponent("sub1"))
        try writeFile(sub1.appendingPathComponent("b.bin"), bytes: 5_000)
        try writeFile(sub1.appendingPathComponent("c.bin"), bytes: 20_000)
        let deep = try makeDirectory(sub1.appendingPathComponent("deep"))
        try writeFile(deep.appendingPathComponent("d.bin"), bytes: 8_000)
        let sub2 = try makeDirectory(root.appendingPathComponent("sub2"))
        try writeFile(sub2.appendingPathComponent("e.bin"), bytes: 4_096)

        let tree = try await runScanToCompletion(at: root)
        let expected = try referenceAllocatedSize(of: root)

        XCTAssertGreaterThan(expected, 0)
        XCTAssertEqual(tree.allocatedSize, expected, "root total must match the reference walk")

        // Directory subtree totals must also match the reference for that subtree.
        let sub1Node = try XCTUnwrap(child(named: "sub1", of: tree))
        XCTAssertEqual(sub1Node.allocatedSize, try referenceAllocatedSize(of: sub1))

        // Structure sanity.
        XCTAssertTrue(tree.isDirectory)
        XCTAssertEqual(Set(tree.children!.map(\.name)), ["a.bin", "sub1", "sub2"])
    }

    // MARK: - Hard links counted once

    func testHardLinkCountedOnce() async throws {
        let dir = try makeDirectory(root.appendingPathComponent("dir"))
        let original = dir.appendingPathComponent("original.bin")
        try writeFile(original, bytes: 150_000)
        let link = root.appendingPathComponent("link.bin")
        try createHardLink(at: link, to: original)

        let singleAllocation = fileAllocatedSize(original)
        XCTAssertGreaterThan(singleAllocation, 0)

        let tree = try await runScanToCompletion(at: root)

        // Both the original and the hard link appear as nodes...
        let fileNodes = allLeafNodes(tree)
        XCTAssertEqual(fileNodes.count, 2)
        // ...but the shared inode is counted exactly once.
        XCTAssertEqual(tree.allocatedSize, singleAllocation,
                       "hard-linked inode must be counted once, not twice")
    }

    // MARK: - Symlinks are not followed

    func testSymlinkNotFollowed() async throws {
        // A sizeable real subtree, plus a symlink pointing at it.
        let target = try makeDirectory(root.appendingPathComponent("target"))
        try writeFile(target.appendingPathComponent("big.bin"), bytes: 200_000)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let targetAllocation = try referenceAllocatedSize(of: target)
        XCTAssertGreaterThan(targetAllocation, 100_000)

        let tree = try await runScanToCompletion(at: root)

        // The target's bytes are counted once (via the real path), not twice via the link.
        // Tolerance covers only the symlink's own on-disk size (well under one block).
        XCTAssertLessThan(abs(tree.allocatedSize - targetAllocation), 4_096,
                          "symlink target must not be traversed / double-counted")

        // The symlink is a leaf, not descended into.
        let linkNode = try XCTUnwrap(child(named: "link", of: tree))
        XCTAssertFalse(linkNode.isDirectory)
        XCTAssertNil(linkNode.children)
    }

    // MARK: - Unreadable directory is flagged, scan continues

    func testUnreadableDirectoryFlaggedAndScanContinues() async throws {
        try XCTSkipIf(geteuid() == 0, "running as root bypasses permission checks")

        let readable = try makeDirectory(root.appendingPathComponent("readable"))
        try writeFile(readable.appendingPathComponent("f.bin"), bytes: 30_000)
        let locked = try makeDirectory(root.appendingPathComponent("locked"))
        try writeFile(locked.appendingPathComponent("secret.bin"), bytes: 90_000)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)

        let tree = try await runScanToCompletion(at: root)

        let lockedNode = try XCTUnwrap(child(named: "locked", of: tree))
        XCTAssertTrue(lockedNode.isUnreadable, "unreadable directory must be flagged")
        XCTAssertEqual(lockedNode.allocatedSize, 0)

        // The scan still completed and the readable side is fully accounted for.
        XCTAssertEqual(tree.allocatedSize, try referenceAllocatedSize(of: root))
        XCTAssertGreaterThan(tree.allocatedSize, 0)
    }

    // MARK: - Cancellation stops the scan

    func testCancellationStopsScan() async throws {
        // Scanning a very large read-only tree cannot finish within the cancel window,
        // so cancellation must prevent a `.finished` update from ever arriving.
        let large = URL(fileURLWithPath: "/System/Library")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: large.path),
                          "/System/Library is required for the cancellation test")

        let scanner = DiskScanner()
        let scanTask = Task { () -> Bool in
            for try await update in scanner.scan(at: large) {
                if case .finished = update { return true }
            }
            return false
        }

        try await Task.sleep(nanoseconds: 30_000_000)  // 30 ms into a multi-second scan
        scanTask.cancel()

        do {
            let finished = try await scanTask.value
            XCTAssertFalse(finished, "scan must not complete after cancellation")
        } catch is CancellationError {
            // Acceptable: cancellation surfaced as a thrown error.
        }
    }

    // MARK: - Dataless-materialization policy

    /// Collects thread-local iopolicy readings taken on a dedicated worker thread. A reference
    /// type so it can be shared with the probe thread without capturing mutable locals.
    private final class PolicyProbeResult: @unchecked Sendable {
        var original: Int32 = -1
        var returnedPrevious: Int32 = -1
        var afterDisable: Int32 = -1
        var afterRestore: Int32 = -1
    }

    func testDisableAndRestoreDatalessMaterializationOnThread() throws {
        let result = PolicyProbeResult()
        let done = DispatchSemaphore(value: 0)

        // Run on a dedicated thread so the test runner's own thread policy stays untouched.
        let thread = Thread {
            result.original =
                getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
            result.returnedPrevious = ScanCoordinator.disableDatalessMaterialization()
            result.afterDisable =
                getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
            ScanCoordinator.restoreDatalessMaterialization(result.returnedPrevious)
            result.afterRestore =
                getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
            done.signal()
        }
        thread.start()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "policy probe thread must finish")

        XCTAssertEqual(result.returnedPrevious, result.original,
                       "disable must return the pre-existing policy value")
        XCTAssertEqual(result.afterDisable, IOPOL_MATERIALIZE_DATALESS_FILES_OFF,
                       "materialization must be OFF after disabling on the thread")
        XCTAssertEqual(result.afterRestore, result.original,
                       "restore must return the policy to its original value")
    }

    func testScanSucceedsWithDatalessPolicyActive() async throws {
        // A normal tree still scans correctly while workerLoop sets and defer-restores the
        // per-thread dataless-materialization policy.
        try writeFile(root.appendingPathComponent("a.bin"), bytes: 12_000)
        let sub = try makeDirectory(root.appendingPathComponent("sub"))
        try writeFile(sub.appendingPathComponent("b.bin"), bytes: 6_000)

        let tree = try await runScanToCompletion(at: root)

        XCTAssertGreaterThan(tree.allocatedSize, 0)
        XCTAssertEqual(tree.allocatedSize, try referenceAllocatedSize(of: root),
                       "scan total must match the reference walk with the policy active")
    }

    // MARK: - Scan driver

    private func runScanToCompletion(at url: URL) async throws -> FileNode {
        let scanner = DiskScanner()
        for try await update in scanner.scan(at: url) {
            if case .finished(let tree) = update { return tree }
        }
        XCTFail("scan finished without a .finished update")
        throw ScanError.cannotAccessRoot(path: url.path, errno: 0)
    }

    // MARK: - Reference walk (independent of getattrlistbulk)

    /// Mirrors the scanner's semantics using POSIX `lstat` (structure) and
    /// `URLResourceValues.totalFileAllocatedSize` (size): files only, hard links once,
    /// symlinks not followed, no crossing device boundaries, unreadable directories = 0.
    private func referenceAllocatedSize(of rootURL: URL) throws -> Int64 {
        var rootStat = stat()
        guard lstat(rootURL.path, &rootStat) == 0 else { return 0 }
        let rootDev = rootStat.st_dev
        var seen = Set<InodeKey>()

        func walk(_ url: URL) -> Int64 {
            var st = stat()
            guard lstat(url.path, &st) == 0 else { return 0 }
            if st.st_dev != rootDev { return 0 }

            switch st.st_mode & S_IFMT {
            case UInt16(S_IFLNK):
                return Int64(st.st_blocks) * 512  // own size; not followed
            case UInt16(S_IFDIR):
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path)
                else { return 0 }
                return names.reduce(0) { $0 + walk(url.appendingPathComponent($1)) }
            default:
                if st.st_nlink > 1 {
                    if !seen.insert(InodeKey(dev: st.st_dev, ino: st.st_ino)).inserted {
                        return 0
                    }
                }
                return fileAllocatedSize(url)
            }
        }
        return walk(rootURL)
    }

    private struct InodeKey: Hashable {
        let dev: dev_t
        let ino: ino_t
    }

    private func fileAllocatedSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? 0)
    }

    // MARK: - Tree helpers

    private func child(named name: String, of node: FileNode) -> FileNode? {
        node.children?.first { $0.name == name }
    }

    private func allLeafNodes(_ node: FileNode) -> [FileNode] {
        guard let children = node.children else { return [node] }
        return children.flatMap { $0.children == nil ? [$0] : allLeafNodes($0) }
    }

    // MARK: - Fixture builders

    private static func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiscFreeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func makeDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeFile(_ url: URL, bytes: Int) throws {
        let data = Data(repeating: 0xAB, count: bytes)
        try data.write(to: url)
    }

    private func createHardLink(at link: URL, to original: URL) throws {
        try FileManager.default.linkItem(at: original, to: link)
    }

    private func restorePermissions(_ url: URL) {
        guard let enumerator = FileManager.default.enumerator(atPath: url.path) else { return }
        chmod(url.path, 0o755)
        for case let relative as String in enumerator {
            chmod(url.appendingPathComponent(relative).path, 0o755)
        }
    }
}
