import XCTest
import Darwin
import Synchronization
@testable import StackdustCore

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

    // MARK: - Directory claims (firmlink dedup)

    func testDirectoryClaimsFirstWinsRepeatLoses() {
        let claims = ScanCoordinator.DirectoryClaims()
        XCTAssertTrue(claims.claim(device: 1, fileID: 100), "the first claim of a key must win")
        XCTAssertFalse(claims.claim(device: 1, fileID: 100), "a repeat claim of the same key must lose")
        XCTAssertFalse(claims.claim(device: 1, fileID: 100), "further repeats must keep losing")
    }

    func testDirectoryClaimsDistinctKeysAreIndependent() {
        let claims = ScanCoordinator.DirectoryClaims()
        // A different fileID on the same device is a distinct directory.
        XCTAssertTrue(claims.claim(device: 1, fileID: 100))
        XCTAssertTrue(claims.claim(device: 1, fileID: 101), "a different fileID is a distinct claim")
        // The same fileID on a different device is also distinct.
        XCTAssertTrue(claims.claim(device: 2, fileID: 100), "a different device is a distinct claim")
        // Each is now taken.
        XCTAssertFalse(claims.claim(device: 1, fileID: 100))
        XCTAssertFalse(claims.claim(device: 1, fileID: 101))
        XCTAssertFalse(claims.claim(device: 2, fileID: 100))
    }

    func testDirectoryClaimsConcurrentSingleWinner() {
        // Many threads racing to claim one key must yield exactly one winner.
        let claims = ScanCoordinator.DirectoryClaims()
        let winners = Atomic<Int>(0)
        DispatchQueue.concurrentPerform(iterations: 256) { _ in
            if claims.claim(device: 7, fileID: 4242) {
                winners.wrappingAdd(1, ordering: .relaxed)
            }
        }
        XCTAssertEqual(winners.load(ordering: .relaxed), 1,
                       "concurrent claims of one key must produce exactly one winner")
    }

    // MARK: - Firmlink dedup must not skip real directories

    func testNestedScanMatchesReferenceAndRescanIsStable() throws {
        // Every real directory has a unique fileID, so claiming directories by (device, fileID)
        // must skip nothing: a normal nested tree must still match the reference walk byte-for-byte.
        try writeFile(root.appendingPathComponent("a.bin"), bytes: 10_000)
        let sub1 = try makeDirectory(root.appendingPathComponent("sub1"))
        try writeFile(sub1.appendingPathComponent("b.bin"), bytes: 5_000)
        let deep = try makeDirectory(sub1.appendingPathComponent("deep"))
        try writeFile(deep.appendingPathComponent("d.bin"), bytes: 8_000)
        let sub2 = try makeDirectory(root.appendingPathComponent("sub2"))
        try writeFile(sub2.appendingPathComponent("e.bin"), bytes: 4_096)

        let expected = try referenceAllocatedSize(of: root)
        XCTAssertGreaterThan(expected, 0)

        // Two consecutive scans, a fresh coordinator each: the root-claim in init must not carry
        // over, so both runs return the full total.
        let first = try ScanCoordinator(root: root, workerCount: 4).run()
        XCTAssertEqual(first.allocatedSize, expected,
                       "first scan must match the reference walk (nothing skipped)")

        let second = try ScanCoordinator(root: root, workerCount: 4).run()
        XCTAssertEqual(second.allocatedSize, expected,
                       "rescan must return the same total; the root claim must not leak across runs")
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

    // MARK: - Errno → unreadable-reason mapping

    func testUnreadableReasonMapsEdeadlkToCloudEvicted() {
        // EDEADLK is the kernel's fail-fast signal for a dataless (iCloud-evicted) directory when
        // materialization is disabled on the calling thread — the one errno that means "evicted".
        XCTAssertEqual(ScanCoordinator.unreadableReason(forOpenErrno: EDEADLK), .cloudEvicted)

        // Every other error is a genuine read failure. (Cannot fabricate a dataless dir in a
        // fixture, hence this pure-function test of the classification instead.)
        for code in [EACCES, EPERM, EIO, ENOENT, ENOTDIR, ELOOP, EINTR] {
            XCTAssertEqual(ScanCoordinator.unreadableReason(forOpenErrno: code), .unreadable,
                           "errno \(code) must map to a genuine read failure")
        }
    }

    func testPartialSnapshotPropagatesUnreadableAndCloudEvictedFlags() throws {
        // A focus chain (chain → mid → leaf) plus a non-chain sibling, so the snapshot exercises
        // all three copy paths: copyFocusChain (chain ancestor), copySubtree (focus + descendants),
        // and copyShallow (the non-chain sibling).
        let chain = try makeDirectory(root.appendingPathComponent("chain"))
        let mid = try makeDirectory(chain.appendingPathComponent("mid"))
        try writeFile(mid.appendingPathComponent("leaf.bin"), bytes: 50_000)
        let sib = try makeDirectory(root.appendingPathComponent("sib"))
        try writeFile(sib.appendingPathComponent("s.bin"), bytes: 40_000)

        let coordinator = try ScanCoordinator(root: root, workerCount: 4)
        let tree = try coordinator.run()

        // Flag two originals after the scan (the two flags are mutually exclusive per node in
        // production; a copy must faithfully carry whichever is set).
        let origChain = try XCTUnwrap(child(named: "chain", of: tree))
        origChain.isUnreadable = true
        let origSib = try XCTUnwrap(child(named: "sib", of: tree))
        origSib.isCloudEvicted = true

        // copySubtree path: a root-anchored full snapshot copies every descendant.
        let full = coordinator.partialSnapshot(
            focusPath: [], maxDepth: 20, topChildren: 100, nodeBudget: 100_000
        )
        XCTAssertTrue(try XCTUnwrap(child(named: "chain", of: full)).isUnreadable)
        XCTAssertTrue(try XCTUnwrap(child(named: "sib", of: full)).isCloudEvicted)
        XCTAssertFalse(try XCTUnwrap(child(named: "sib", of: full)).isUnreadable)

        // copyFocusChain (chain ancestor) + copyShallow (non-chain sibling).
        let focused = coordinator.partialSnapshot(
            focusPath: ["chain", "mid"], maxDepth: 2, topChildren: 100, nodeBudget: 100_000
        )
        XCTAssertTrue(try XCTUnwrap(child(named: "chain", of: focused)).isUnreadable,
                      "copyFocusChain must carry the flag on a chain ancestor")
        XCTAssertTrue(try XCTUnwrap(child(named: "sib", of: focused)).isCloudEvicted,
                      "copyShallow must carry the flag on a non-chain sibling")
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

    // MARK: - Partial snapshots

    func testPartialSnapshotCopySemanticsAndCaps() throws {
        // A fixture that is wide (to trip topChildren), deep (to trip maxDepth), and large enough
        // (to trip nodeBudget). File sizes are spaced well over one block apart so their allocated
        // sizes are distinct and their descending order is unambiguous.
        try writeFile(root.appendingPathComponent("top.bin"), bytes: 10_000)

        let wide = try makeDirectory(root.appendingPathComponent("wide"))
        for i in 1...5 {
            try writeFile(wide.appendingPathComponent("big_\(i).bin"), bytes: i * 100_000)
        }

        let deep = try makeDirectory(root.appendingPathComponent("deep"))
        let d1 = try makeDirectory(deep.appendingPathComponent("d1"))
        let d2 = try makeDirectory(d1.appendingPathComponent("d2"))
        let d3 = try makeDirectory(d2.appendingPathComponent("d3"))
        try writeFile(d3.appendingPathComponent("leaf.bin"), bytes: 50_000)

        // Run a coordinator to completion, then snapshot the finished tree. This is the easiest
        // deterministic path and still exercises every copy semantic: the aggregated sizes are
        // authoritative, so the assertions below have exact expected values.
        let coordinator = try ScanCoordinator(root: root, workerCount: 4)
        let tree = try coordinator.run()

        // Full-fidelity copy: distinct instances, parent links, exact sizes, descending order.
        let full = coordinator.partialSnapshot(
            focusPath: [], maxDepth: 20, topChildren: 100, nodeBudget: 100_000
        )
        XCTAssertEqual(full.name, tree.name)
        XCTAssertEqual(full.allocatedSize, tree.allocatedSize, "root size must equal aggregated truth")
        XCTAssertFalse(full === tree, "snapshot root must be a distinct instance")

        let origWide = try XCTUnwrap(child(named: "wide", of: tree))
        let copyWide = try XCTUnwrap(child(named: "wide", of: full))
        XCTAssertFalse(copyWide === origWide, "copied nodes must be distinct instances from originals")
        XCTAssertEqual(copyWide.allocatedSize, origWide.allocatedSize)
        assertWellFormedCopy(full, expectedParent: nil)

        // topChildren cap: the 5-wide directory keeps only its 3 largest, sorted descending.
        let capped = coordinator.partialSnapshot(
            focusPath: [], maxDepth: 5, topChildren: 3, nodeBudget: 100_000
        )
        let cappedWide = try XCTUnwrap(child(named: "wide", of: capped))
        let cappedNames = cappedWide.children?.map(\.name) ?? []
        XCTAssertEqual(cappedNames, ["big_5.bin", "big_4.bin", "big_3.bin"],
                       "topChildren must keep the largest children in descending order")

        // maxDepth cap: at depth 2 the directory is copied but not descended into.
        let shallow = coordinator.partialSnapshot(
            focusPath: [], maxDepth: 2, topChildren: 100, nodeBudget: 100_000
        )
        let shallowDeep = try XCTUnwrap(child(named: "deep", of: shallow))
        let shallowD1 = try XCTUnwrap(child(named: "d1", of: shallowDeep))
        XCTAssertNotNil(shallowD1.children, "a directory copy keeps a (possibly empty) children array")
        XCTAssertEqual(shallowD1.children?.count, 0, "a directory at maxDepth must have no copied children")

        // nodeBudget cap: the copy stops after exactly `budget` nodes.
        let budgeted = coordinator.partialSnapshot(
            focusPath: [], maxDepth: 20, topChildren: 100, nodeBudget: 4
        )
        XCTAssertEqual(countNodes(budgeted), 4, "nodeBudget must cap the total number of copied nodes")
    }

    func testPartialSnapshotSpendsBudgetBreadthFirst() throws {
        // The focus (root) has six child directories; one (c0) dominates in both size and node
        // count. A depth-first budget would descend into that dominant child and bury the whole
        // budget in its subtree, dropping the other five top-level sectors. Breadth-first must copy
        // all six children before spending anything on level 2.
        let childCount = 6
        for c in 0..<childCount {
            let dir = try makeDirectory(root.appendingPathComponent("c\(c)"))
            if c == 0 {
                // The dominant child: eight large grandchildren — more than the budget left after
                // the root and all six children, so a depth-first copy would exhaust the budget here.
                for g in 0..<8 {
                    try writeFile(dir.appendingPathComponent("g\(g).bin"), bytes: 360_000 + g * 20_000)
                }
            } else {
                // Smaller children with a few grandchildren each; each total stays well below c0.
                for g in 0..<3 {
                    try writeFile(dir.appendingPathComponent("g\(g).bin"), bytes: (childCount - c) * 20_000)
                }
            }
        }

        let coordinator = try ScanCoordinator(root: root, workerCount: 4)
        _ = try coordinator.run()

        // Budget = root (1) + all six children (6) + three grandchildren (3).
        let budget = 1 + childCount + 3
        let snap = coordinator.partialSnapshot(
            focusPath: [], maxDepth: 5, topChildren: 32, nodeBudget: budget
        )

        // All six top-level sectors survive, even though c0 dominates (old depth-first order kept
        // only c0 and its first children).
        XCTAssertEqual(Set(snap.children?.map(\.name) ?? []),
                       Set((0..<childCount).map { "c\($0)" }),
                       "breadth-first must copy every top-level child before descending")
        // The budget is spent exactly, not left partly unused.
        XCTAssertEqual(countNodes(snap), budget, "the copy must contain exactly nodeBudget nodes")
        // The three level-2 nodes all belong to the dominant child (processed first); the other
        // five children have no copied grandchildren yet.
        let c0 = try XCTUnwrap(child(named: "c0", of: snap))
        XCTAssertEqual(c0.children?.count, 3, "leftover budget goes to the largest child first")
        for c in 1..<childCount {
            let node = try XCTUnwrap(child(named: "c\(c)", of: snap))
            XCTAssertEqual(node.children?.count, 0,
                           "no budget remains for smaller children's grandchildren")
        }
        assertWellFormedCopy(snap, expectedParent: nil)
    }

    func testPartialSnapshotLevelCompletenessCutsOffCleanly() throws {
        // Three levels below the focus. A budget that runs out partway through level 2 must leave
        // level 1 fully populated and produce no level-3 node at all: a level-3 node can only be
        // created by expanding a level-2 node, which never happens once the budget is spent.
        let level1Count = 4
        let level2PerChild = 5
        for a in 0..<level1Count {
            let child = try makeDirectory(root.appendingPathComponent("a\(a)"))
            for b in 0..<level2PerChild {
                let grand = try makeDirectory(child.appendingPathComponent("b\(b)"))
                // Two great-grandchildren (level 3) to prove none are copied. The (level1Count - a)
                // factor makes a0 the largest child and keeps every child's total distinct.
                for c in 0..<2 {
                    try writeFile(grand.appendingPathComponent("c\(c).bin"),
                                  bytes: (level1Count - a) * 100_000 + b * 10_000 + 10_000)
                }
            }
        }

        let coordinator = try ScanCoordinator(root: root, workerCount: 4)
        _ = try coordinator.run()

        // Budget = root (1) + all four level-1 children (4) + three level-2 nodes (3): cuts off
        // partway through level 2 (there are 20 level-2 nodes in total).
        let budget = 1 + level1Count + 3
        let snap = coordinator.partialSnapshot(
            focusPath: [], maxDepth: 8, topChildren: 32, nodeBudget: budget
        )

        // Level 1 is complete.
        XCTAssertEqual(snap.children?.count, level1Count, "level 1 must be copied in full")

        // Exactly three level-2 nodes were copied, and every one of them is childless — no level-3
        // node exists anywhere in the copy.
        let level2Nodes = (snap.children ?? []).flatMap { $0.children ?? [] }
        XCTAssertEqual(level2Nodes.count, 3, "the budget must cut off partway through level 2")
        for node in level2Nodes {
            XCTAssertEqual(node.children?.count, 0, "no level-3 node may be present")
        }
        XCTAssertEqual(countNodes(snap), budget, "the copy must contain exactly nodeBudget nodes")
        assertWellFormedCopy(snap, expectedParent: nil)
    }

    func testPartialSnapshotDuringLiveScanIsMonotonicAndWellFormed() throws {
        // A few thousand small files/dirs so the scan runs long enough to observe live snapshots.
        for i in 0..<30 {
            let dir = try makeDirectory(root.appendingPathComponent("d\(i)"))
            for j in 0..<40 {
                try writeFile(dir.appendingPathComponent("f\(j).bin"), bytes: 1024 + j * 16)
            }
            let nested = try makeDirectory(dir.appendingPathComponent("nested"))
            for k in 0..<10 {
                try writeFile(nested.appendingPathComponent("n\(k).bin"), bytes: 2048)
            }
        }

        let coordinator = try ScanCoordinator(
            root: root, workerCount: ProcessInfo.processInfo.activeProcessorCount
        )
        let outcome = ScanRunOutcome()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do { outcome.tree = try coordinator.run() } catch { outcome.error = error }
            done.signal()
        }

        let rootPath = root.standardizedFileURL.path
        var previousRootSize: Int64 = -1
        var snapshotCount = 0
        // Poll for completion, taking a snapshot each turn while the scan runs concurrently.
        while done.wait(timeout: .now()) == .timedOut {
            let snap = coordinator.partialSnapshot(
                focusPath: [], maxDepth: 5, topChildren: 32, nodeBudget: 4000
            )
            snapshotCount += 1
            XCTAssertEqual(snap.name, rootPath, "snapshot root name must match the scan root")
            assertAllSizesNonNegative(snap)
            XCTAssertGreaterThanOrEqual(snap.allocatedSize, previousRootSize,
                                        "root partial size must be monotonically non-decreasing")
            previousRootSize = snap.allocatedSize
        }

        if let error = outcome.error { throw error }
        XCTAssertGreaterThan(snapshotCount, 0, "at least one snapshot must be taken during the live scan")
        let tree = try XCTUnwrap(outcome.tree)
        XCTAssertEqual(tree.allocatedSize, try referenceAllocatedSize(of: root),
                       "final scan total must match the reference walk")
    }

    func testStreamPartialsAreWellFormedAndPrecedeFinished() async throws {
        try writeFile(root.appendingPathComponent("a.bin"), bytes: 40_000)
        let sub = try makeDirectory(root.appendingPathComponent("sub"))
        try writeFile(sub.appendingPathComponent("b.bin"), bytes: 20_000)
        let deep = try makeDirectory(sub.appendingPathComponent("deep"))
        try writeFile(deep.appendingPathComponent("c.bin"), bytes: 60_000)

        let scanner = DiskScanner()
        let rootPath = root.standardizedFileURL.path
        var finishedTree: FileNode?
        var finishedCount = 0

        // A tiny partial interval maximizes the chance of observing partials; the test does not
        // require any (a fast machine may finish first), only that any received are well-formed
        // and precede the single terminal `.finished`.
        for try await update in scanner.scan(at: root, partialInterval: .milliseconds(1)) {
            switch update {
            case .started:
                break
            case .progress:
                break
            case .partial(let snapshot):
                XCTAssertNil(finishedTree, "a .partial must never arrive after .finished")
                XCTAssertEqual(snapshot.name, rootPath, "partial root name must match the scan root")
                assertAllSizesNonNegative(snapshot)
            case .finished(let tree):
                finishedCount += 1
                finishedTree = tree
            }
        }

        XCTAssertEqual(finishedCount, 1, "the stream must end with exactly one .finished")
        let tree = try XCTUnwrap(finishedTree)
        XCTAssertEqual(tree.allocatedSize, try referenceAllocatedSize(of: root),
                       "finished total must match the reference walk")
    }

    func testPartialSnapshotFollowsFocusPath() throws {
        // A fixture where, at every level along the focus path, the chain child is deliberately the
        // SMALLER sibling, so a topChildren of 1 would drop it were the chain not force-included.
        // Below the focus the tree is deeper than maxDepth, to prove depth restarts at the focus.
        // Sizes are spaced far apart so block rounding cannot reorder the aggregated totals.
        try writeFile(root.appendingPathComponent("big0.bin"), bytes: 900_000)
        let chain = try makeDirectory(root.appendingPathComponent("chain"))
        try writeFile(chain.appendingPathComponent("big1.bin"), bytes: 300_000)
        let mid = try makeDirectory(chain.appendingPathComponent("mid"))
        try writeFile(mid.appendingPathComponent("big2.bin"), bytes: 100_000)
        let leaf = try makeDirectory(mid.appendingPathComponent("leaf"))
        let l1 = try makeDirectory(leaf.appendingPathComponent("L1"))
        let l2 = try makeDirectory(l1.appendingPathComponent("L2"))
        let l3 = try makeDirectory(l2.appendingPathComponent("L3"))
        try writeFile(l3.appendingPathComponent("deep.bin"), bytes: 10_000)

        let coordinator = try ScanCoordinator(root: root, workerCount: 4)
        _ = try coordinator.run()
        let rootPath = root.standardizedFileURL.path

        // Focus three levels deep, topChildren = 1 so only the single largest sibling plus a
        // force-included chain child can survive at each chain level.
        let focusPath = ["chain", "mid", "leaf"]
        let snap = coordinator.partialSnapshot(
            focusPath: focusPath, maxDepth: 3, topChildren: 1, nodeBudget: 100_000
        )

        // (a) full chain with correct names and parent links, internally well-formed.
        assertWellFormedCopy(snap, expectedParent: nil)
        XCTAssertEqual(snap.name, rootPath, "snapshot root name must match the scan root")
        let snapChain = try XCTUnwrap(child(named: "chain", of: snap))
        XCTAssertTrue(snapChain.parent === snap, "chain's parent must be the snapshot root")
        let snapMid = try XCTUnwrap(child(named: "mid", of: snapChain))
        XCTAssertTrue(snapMid.parent === snapChain, "mid's parent must be the copied chain node")
        let snapLeaf = try XCTUnwrap(child(named: "leaf", of: snapMid))
        XCTAssertTrue(snapLeaf.parent === snapMid, "leaf's parent must be the copied mid node")

        // (b) at every chain level the smaller chain child is present alongside the one largest
        // sibling, even though topChildren is 1.
        XCTAssertEqual(Set(snap.children?.map(\.name) ?? []), ["big0.bin", "chain"],
                       "root keeps its largest sibling plus the force-included chain child")
        XCTAssertEqual(Set(snapChain.children?.map(\.name) ?? []), ["big1.bin", "mid"])
        XCTAssertEqual(Set(snapMid.children?.map(\.name) ?? []), ["big2.bin", "leaf"])
        XCTAssertGreaterThan(
            child(named: "big0.bin", of: snap)?.allocatedSize ?? 0, snapChain.allocatedSize,
            "the chain child must be the smaller sibling, so topChildren=1 would drop it"
        )

        // (c) below the focus, descendants are copied maxDepth (3) levels deep. Because the chain
        // above does NOT consume depth, the focus — itself 3 levels down — still expands fully.
        let snapL1 = try XCTUnwrap(child(named: "L1", of: snapLeaf))
        let snapL2 = try XCTUnwrap(child(named: "L2", of: snapL1))
        let snapL3 = try XCTUnwrap(child(named: "L3", of: snapL2))
        XCTAssertEqual(snapL3.children?.count, 0,
                       "the node at maxDepth below the focus must be copied without its children")
        XCTAssertNil(child(named: "deep.bin", of: snapL3),
                     "content one level past maxDepth must not be copied")

        // (d) an unresolvable tail falls back to the deepest existing ancestor (mid), which becomes
        // the focus and gets its descendants copied with depth measured from itself.
        let fallback = coordinator.partialSnapshot(
            focusPath: ["chain", "mid", "nonexistent"],
            maxDepth: 2, topChildren: 100, nodeBudget: 100_000
        )
        let fbChain = try XCTUnwrap(child(named: "chain", of: fallback))
        let fbMid = try XCTUnwrap(child(named: "mid", of: fbChain))
        XCTAssertNil(child(named: "nonexistent", of: fbMid), "the missing component must not appear")
        XCTAssertEqual(Set(fbMid.children?.map(\.name) ?? []), ["big2.bin", "leaf"],
                       "the fallback focus expands its own children")
        let fbLeaf = try XCTUnwrap(child(named: "leaf", of: fbMid))
        XCTAssertNotNil(child(named: "L1", of: fbLeaf), "depth is measured from the fallback focus")

        // (e) with a tiny nodeBudget the full chain is still present (siblings may be dropped).
        let budgeted = coordinator.partialSnapshot(
            focusPath: focusPath, maxDepth: 3, topChildren: 32, nodeBudget: 1
        )
        let bChain = try XCTUnwrap(child(named: "chain", of: budgeted))
        let bMid = try XCTUnwrap(child(named: "mid", of: bChain))
        XCTAssertNotNil(child(named: "leaf", of: bMid),
                        "the resolved chain must survive even a budget of 1")
    }

    func testStreamBeginsWithLiveScanAndFinishesOnce() async throws {
        try writeFile(root.appendingPathComponent("a.bin"), bytes: 40_000)
        let sub = try makeDirectory(root.appendingPathComponent("sub"))
        try writeFile(sub.appendingPathComponent("b.bin"), bytes: 20_000)
        let deep = try makeDirectory(sub.appendingPathComponent("deep"))
        try writeFile(deep.appendingPathComponent("c.bin"), bytes: 60_000)

        let scanner = DiskScanner()
        var isFirstUpdate = true
        var firstWasStarted = false
        var liveScan: LiveScan?
        var finishedCount = 0
        var finishedTree: FileNode?

        // A tiny partial interval maximizes concurrent snapshot activity while the focus is set.
        for try await update in scanner.scan(at: root, partialInterval: .milliseconds(1)) {
            if isFirstUpdate {
                isFirstUpdate = false
                if case .started(let handle) = update {
                    firstWasStarted = true
                    liveScan = handle
                    // Steer the focus mid-scan; the emitter reads it concurrently and must not crash.
                    handle.focusPath = ["sub"]
                }
            }
            switch update {
            case .started:
                break
            case .progress:
                break
            case .partial:
                break
            case .finished(let tree):
                finishedCount += 1
                finishedTree = tree
            }
        }

        XCTAssertTrue(firstWasStarted, "the first stream update must be .started")
        XCTAssertNotNil(liveScan, "the .started update must carry a LiveScan handle")
        XCTAssertEqual(finishedCount, 1, "the stream must end with exactly one .finished")
        let tree = try XCTUnwrap(finishedTree)
        XCTAssertEqual(tree.allocatedSize, try referenceAllocatedSize(of: root),
                       "finished total must match the reference walk")
    }

    /// Captures the outcome of a `ScanCoordinator.run()` executed on a background thread.
    private final class ScanRunOutcome: @unchecked Sendable {
        var tree: FileNode?
        var error: Error?
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

    private func countNodes(_ node: FileNode) -> Int {
        1 + (node.children?.reduce(0) { $0 + countNodes($1) } ?? 0)
    }

    /// Asserts a partial-snapshot subtree is internally consistent: every node's `parent` points
    /// at its copied parent and each directory's children are sorted by size, descending.
    private func assertWellFormedCopy(
        _ node: FileNode, expectedParent: FileNode?,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(node.parent === expectedParent, "parent link must point within the copy",
                      file: file, line: line)
        guard let children = node.children else { return }
        if children.count > 1 {
            for index in 1..<children.count {
                XCTAssertGreaterThanOrEqual(
                    children[index - 1].allocatedSize, children[index].allocatedSize,
                    "children must be sorted by size, descending", file: file, line: line
                )
            }
        }
        for child in children {
            assertWellFormedCopy(child, expectedParent: node, file: file, line: line)
        }
    }

    private func assertAllSizesNonNegative(
        _ node: FileNode, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(node.allocatedSize, 0, file: file, line: line)
        node.children?.forEach { assertAllSizesNonNegative($0, file: file, line: line) }
    }

    // MARK: - Fixture builders

    private static func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("StackdustTests-\(UUID().uuidString)")
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
