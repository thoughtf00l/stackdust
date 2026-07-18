import XCTest
@testable import StackdustCore

final class TreeSnapshotTests: XCTestCase {

    // MARK: - Synthetic tree helpers (mirror DevClassifierTests; no disk involved)

    private func file(_ name: String, _ size: Int64) -> FileNode {
        FileNode(name: name, isDirectory: false, allocatedSize: size, parent: nil)
    }

    private func dir(_ name: String, _ children: [FileNode]) -> FileNode {
        let node = FileNode(name: name, isDirectory: true, parent: nil)
        node.children = children
        for child in children { child.parent = node }
        node.allocatedSize = children.reduce(0) { $0 + $1.allocatedSize }
        return node
    }

    /// A tree exercising the format's edge cases: unicode names, an unreadable directory, an
    /// iCloud-evicted directory, a zero-size file (the hard-link convention), and an empty directory.
    private func sampleTree() -> FileNode {
        let locked = dir("locked", [])
        locked.isUnreadable = true
        let evicted = dir("evicted", [])
        evicted.isCloudEvicted = true
        return dir("/scan root", [
            dir("Папка с пробелами", [file("файл ёё.dat", 31_457_280)]),
            dir("empty", []),
            locked,
            evicted,
            file("hardlink-second-occurrence", 0),
            file("plain.bin", 1_234_567),
        ])
    }

    private func assertEqualTrees(_ a: FileNode, _ b: FileNode, path: String = "") {
        XCTAssertEqual(a.name, b.name, "name at \(path)")
        XCTAssertEqual(a.isDirectory, b.isDirectory, "isDirectory at \(path)/\(a.name)")
        XCTAssertEqual(a.isUnreadable, b.isUnreadable, "isUnreadable at \(path)/\(a.name)")
        XCTAssertEqual(a.isCloudEvicted, b.isCloudEvicted, "isCloudEvicted at \(path)/\(a.name)")
        XCTAssertEqual(a.allocatedSize, b.allocatedSize, "allocatedSize at \(path)/\(a.name)")
        XCTAssertEqual(a.children?.count, b.children?.count, "child count at \(path)/\(a.name)")
        for (childA, childB) in zip(a.children ?? [], b.children ?? []) {
            XCTAssertTrue(childB.parent === b, "parent link at \(path)/\(a.name)/\(childA.name)")
            assertEqualTrees(childA, childB, path: path + "/" + a.name)
        }
    }

    // MARK: - Round trip

    func testRoundTripPreservesTreeAndHeader() throws {
        let root = sampleTree()
        let date = Date(timeIntervalSince1970: 1_750_000_000.25)

        let data = TreeSnapshot.encode(root, scanDate: date)
        let decoded = try TreeSnapshot.decode(data)

        XCTAssertEqual(decoded.header.rootPath, "/scan root")
        XCTAssertEqual(decoded.header.scanDate, date)
        XCTAssertEqual(decoded.header.totalBytes, root.allocatedSize)
        assertEqualTrees(root, decoded.root)
        XCTAssertNil(decoded.root.parent)
    }

    func testRoundTripPreservesUnreadableAndCloudEvictedFlags() throws {
        let decoded = try TreeSnapshot.decode(
            TreeSnapshot.encode(sampleTree(), scanDate: Date(timeIntervalSince1970: 0))
        ).root
        let children = try XCTUnwrap(decoded.children)

        let locked = try XCTUnwrap(children.first { $0.name == "locked" })
        XCTAssertTrue(locked.isUnreadable)
        XCTAssertFalse(locked.isCloudEvicted, "the two flags are mutually exclusive")

        let evicted = try XCTUnwrap(children.first { $0.name == "evicted" })
        XCTAssertTrue(evicted.isCloudEvicted)
        XCTAssertFalse(evicted.isUnreadable, "the two flags are mutually exclusive")

        let plain = try XCTUnwrap(children.first { $0.name == "plain.bin" })
        XCTAssertFalse(plain.isUnreadable)
        XCTAssertFalse(plain.isCloudEvicted)
    }

    func testDecodedTreeLeavesClassificationAtDefaults() throws {
        let root = sampleTree()
        root.devSize = 999
        root.devCategory = .xcodeBuild

        let data = TreeSnapshot.encode(root, scanDate: Date(timeIntervalSince1970: 0))
        let decoded = try TreeSnapshot.decode(data).root

        XCTAssertEqual(decoded.devSize, 0, "devSize is not persisted; a classify pass re-fills it")
        XCTAssertNil(decoded.devCategory)
    }

    func testHeaderDecodesWithoutFullTree() throws {
        let data = TreeSnapshot.encode(sampleTree(), scanDate: Date(timeIntervalSince1970: 42))
        let header = try TreeSnapshot.decodeHeader(data)
        XCTAssertEqual(header.rootPath, "/scan root")
        XCTAssertEqual(header.scanDate, Date(timeIntervalSince1970: 42))
    }

    // MARK: - Corruption

    func testBadMagicThrowsCorrupted() {
        var data = TreeSnapshot.encode(sampleTree(), scanDate: Date(timeIntervalSince1970: 0))
        data[0] = UInt8(ascii: "X")
        XCTAssertThrowsError(try TreeSnapshot.decode(data)) { error in
            XCTAssertEqual(error as? SnapshotError, .corrupted)
        }
    }

    func testUnknownVersionThrowsUnsupported() {
        var data = TreeSnapshot.encode(sampleTree(), scanDate: Date(timeIntervalSince1970: 0))
        data[4] = 99  // the version byte follows the 4-byte magic
        XCTAssertThrowsError(try TreeSnapshot.decode(data)) { error in
            XCTAssertEqual(error as? SnapshotError, .unsupportedVersion(99))
        }
    }

    /// A snapshot from the previous format version (1, before the cloud-evicted flag) must be
    /// rejected so the app degrades to a fresh scan rather than misreading old flag bytes.
    func testOldVersionSnapshotRejected() {
        var data = TreeSnapshot.encode(sampleTree(), scanDate: Date(timeIntervalSince1970: 0))
        data[4] = 1  // downgrade the version byte to the pre-cloud-evicted format
        XCTAssertThrowsError(try TreeSnapshot.decode(data)) { error in
            XCTAssertEqual(error as? SnapshotError, .unsupportedVersion(1))
        }
        XCTAssertThrowsError(try TreeSnapshot.decodeHeader(data)) { error in
            XCTAssertEqual(error as? SnapshotError, .unsupportedVersion(1))
        }
    }

    func testTruncatedDataThrowsCorruptedNotCrash() {
        let data = TreeSnapshot.encode(sampleTree(), scanDate: Date(timeIntervalSince1970: 0))
        // Every truncation point must fail cleanly; step through a spread of prefixes.
        for length in stride(from: 0, to: data.count, by: 7) {
            XCTAssertThrowsError(
                try TreeSnapshot.decode(data.prefix(length)),
                "prefix of \(length) bytes"
            )
        }
    }

    func testEmptyDataThrowsCorrupted() {
        XCTAssertThrowsError(try TreeSnapshot.decode(Data())) { error in
            XCTAssertEqual(error as? SnapshotError, .corrupted)
        }
    }
}
