import XCTest
@testable import DiscFreeCLI
@testable import DiscFreeCore

final class TreeShaperTests: XCTestCase {
    private let file = TreeFixtures.file
    private let dir = TreeFixtures.dir

    // MARK: - Depth

    func testDepthZeroKeepsOnlyRoot() {
        let root = dir("/root", [file("a", 10), dir("sub", [file("b", 5)])])
        let result = TreeShaper.shape(root, options: .init(maxDepth: 0, top: 100, minSize: 0))

        XCTAssertEqual(result.node.children, [], "no children below the root at depth 0")
        XCTAssertTrue(result.truncated, "the root has children that were dropped")
    }

    func testDepthLimitsDescent() {
        let grandchild = file("deep", 1)
        let child = dir("sub", [grandchild])
        let root = dir("/root", [child])

        let depthOne = TreeShaper.shape(root, options: .init(maxDepth: 1, top: 100, minSize: 0))
        XCTAssertEqual(depthOne.node.children?.count, 1)
        XCTAssertEqual(depthOne.node.children?.first?.children, [], "grandchild pruned at depth 1")
        XCTAssertTrue(depthOne.truncated)

        let depthTwo = TreeShaper.shape(root, options: .init(maxDepth: 2, top: 100, minSize: 0))
        XCTAssertEqual(depthTwo.node.children?.first?.children?.count, 1, "grandchild kept at depth 2")
        XCTAssertFalse(depthTwo.truncated)
    }

    // MARK: - Top N + ordering

    func testTopKeepsLargestFirst() {
        let root = dir("/root", [file("small", 1), file("big", 100), file("mid", 50)])
        let result = TreeShaper.shape(root, options: .init(maxDepth: 1, top: 2, minSize: 0))

        XCTAssertEqual(result.node.children?.map(\.name), ["big", "mid"], "largest two, ordered desc")
        XCTAssertTrue(result.truncated, "'small' was dropped by --top")
    }

    func testTopNotTruncatedWhenAllFit() {
        let root = dir("/root", [file("a", 2), file("b", 1)])
        let result = TreeShaper.shape(root, options: .init(maxDepth: 1, top: 5, minSize: 0))
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.node.children?.map(\.name), ["a", "b"])
    }

    func testEqualSizesBreakTiesByName() {
        let root = dir("/root", [file("charlie", 10), file("alpha", 10), file("bravo", 10)])
        let result = TreeShaper.shape(root, options: .init(maxDepth: 1, top: 100, minSize: 0))
        XCTAssertEqual(result.node.children?.map(\.name), ["alpha", "bravo", "charlie"])
    }

    // MARK: - Min-size

    func testMinSizePrunesSmallEntries() {
        let root = dir("/root", [file("keep", 1_000), file("drop", 10)])
        let result = TreeShaper.shape(root, options: .init(maxDepth: 1, top: 100, minSize: 500))

        XCTAssertEqual(result.node.children?.map(\.name), ["keep"])
        XCTAssertTrue(result.truncated)
    }

    func testMinSizeKeepsEqualToThreshold() {
        let root = dir("/root", [file("exact", 500)])
        let result = TreeShaper.shape(root, options: .init(maxDepth: 1, top: 100, minSize: 500))
        XCTAssertEqual(result.node.children?.map(\.name), ["exact"], ">= threshold is kept")
        XCTAssertFalse(result.truncated)
    }

    // MARK: - Node shape

    func testFileNodeOmitsChildren() {
        let root = dir("/root", [file("a", 10)])
        let result = TreeShaper.shape(root, options: .init(maxDepth: 1, top: 100, minSize: 0))
        let leaf = result.node.children?.first
        XCTAssertEqual(leaf?.dir, false)
        XCTAssertNil(leaf?.children, "files carry no children array")
        XCTAssertNil(leaf?.unreadable, "readable nodes carry no unreadable flag")
    }

    func testUnreadableFlagged() {
        let root = dir("/root", [TreeFixtures.unreadableDir("blocked")])
        let result = TreeShaper.shape(root, options: .init(maxDepth: 1, top: 100, minSize: 0))
        XCTAssertEqual(result.node.children?.first?.unreadable, true)
        XCTAssertNil(result.node.children?.first?.cloud_evicted, "unreadable is not cloud-evicted")
    }

    func testCloudEvictedFlagged() {
        let root = dir("/root", [TreeFixtures.cloudEvictedDir("in-cloud")])
        let result = TreeShaper.shape(root, options: .init(maxDepth: 1, top: 100, minSize: 0))
        XCTAssertEqual(result.node.children?.first?.cloud_evicted, true)
        XCTAssertNil(result.node.children?.first?.unreadable, "cloud-evicted is not unreadable")
    }

    func testReadableNodeCarriesNeitherFlag() {
        let root = dir("/root", [file("a", 10)])
        let result = TreeShaper.shape(root, options: .init(maxDepth: 1, top: 100, minSize: 0))
        let leaf = result.node.children?.first
        XCTAssertNil(leaf?.unreadable)
        XCTAssertNil(leaf?.cloud_evicted)
    }

    // MARK: - Counts over the full tree, split by cause

    func testCountUnreadableSpansWholeTreeRegardlessOfBounding() {
        let deep = dir("deep", [TreeFixtures.unreadableDir("x"), TreeFixtures.unreadableDir("y")])
        let root = dir("/root", [deep, TreeFixtures.unreadableDir("z")])
        // Bounding to depth 0 must not affect the count: it walks the real tree.
        XCTAssertEqual(TreeShaper.countUnreadable(root), 3)
    }

    func testCountsSplitUnreadableFromCloudEvicted() {
        // Two genuine failures and three evicted directories, mixed at different depths.
        let deep = dir("deep", [TreeFixtures.unreadableDir("x"), TreeFixtures.cloudEvictedDir("c1")])
        let root = dir("/root", [
            deep,
            TreeFixtures.unreadableDir("z"),
            TreeFixtures.cloudEvictedDir("c2"),
            TreeFixtures.cloudEvictedDir("c3"),
        ])
        XCTAssertEqual(TreeShaper.countUnreadable(root), 2, "evicted dirs must not count as unreadable")
        XCTAssertEqual(TreeShaper.countCloudEvicted(root), 3)
    }
}
