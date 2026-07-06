import XCTest
@testable import DiscFreeCore

final class SnapshotStoreTests: XCTestCase {

    private var tempDirectory: URL!
    private var store: SnapshotStore!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapshotStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = SnapshotStore(directory: tempDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func tree(rootPath: String, fileSize: Int64) -> FileNode {
        let root = FileNode(name: rootPath, isDirectory: true, parent: nil)
        let child = FileNode(name: "payload.bin", isDirectory: false,
                             allocatedSize: fileSize, parent: root)
        root.children = [child]
        root.allocatedSize = fileSize
        return root
    }

    func testSaveThenLoadRoundTrips() throws {
        let root = tree(rootPath: "/scanned/root", fileSize: 4_096)
        try store.save(root, scanDate: Date(timeIntervalSince1970: 100))

        let entries = store.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].header.rootPath, "/scanned/root")
        XCTAssertEqual(entries[0].header.totalBytes, 4_096)

        let loaded = try store.loadTree(entries[0])
        XCTAssertEqual(loaded.name, "/scanned/root")
        XCTAssertEqual(loaded.allocatedSize, 4_096)
        XCTAssertEqual(loaded.children?.first?.name, "payload.bin")
    }

    func testMostRecentPicksNewestScanDate() throws {
        try store.save(tree(rootPath: "/old", fileSize: 1), scanDate: Date(timeIntervalSince1970: 100))
        try store.save(tree(rootPath: "/new", fileSize: 2), scanDate: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(store.entries().count, 2)
        XCTAssertEqual(store.mostRecent()?.header.rootPath, "/new")
    }

    func testSavingSameRootReplacesItsSnapshot() throws {
        try store.save(tree(rootPath: "/root", fileSize: 1), scanDate: Date(timeIntervalSince1970: 100))
        try store.save(tree(rootPath: "/root", fileSize: 2), scanDate: Date(timeIntervalSince1970: 200))

        let entries = store.entries()
        XCTAssertEqual(entries.count, 1, "one snapshot per root path")
        XCTAssertEqual(entries[0].header.totalBytes, 2)
    }

    func testCorruptedFileIsSkippedNotSurfaced() throws {
        try store.save(tree(rootPath: "/good", fileSize: 1), scanDate: Date(timeIntervalSince1970: 100))
        try Data("garbage".utf8).write(
            to: tempDirectory.appendingPathComponent("broken.dfsnap"))

        let entries = store.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].header.rootPath, "/good")
    }

    func testMissingDirectoryYieldsNoEntries() {
        XCTAssertTrue(store.entries().isEmpty)
        XCTAssertNil(store.mostRecent())
    }
}
