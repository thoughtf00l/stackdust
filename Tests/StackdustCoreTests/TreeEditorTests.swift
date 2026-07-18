import XCTest
@testable import StackdustCore

final class TreeEditorTests: XCTestCase {

    // MARK: - Synthetic tree helpers

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

    // MARK: - Removing a leaf

    func testRemoveLeafSubtractsSizeUpTheChain() throws {
        let a1 = file("a1", 100)
        let a2 = file("a2", 200)
        let a = dir("A", [a1, a2])       // 300
        let b = file("B", 50)
        let root = dir("/root", [a, b])  // 350

        let formerParent = try TreeEditor.remove(a1, keeping: root)

        XCTAssertTrue(formerParent === a)
        XCTAssertFalse(a.children!.contains { $0 === a1 })
        XCTAssertNil(a1.parent)
        XCTAssertEqual(a.allocatedSize, 200)
        XCTAssertEqual(root.allocatedSize, 250)
        XCTAssertEqual(b.allocatedSize, 50, "sibling must be untouched")
    }

    // MARK: - Removing a directory subtree

    func testRemoveDirectorySubtractsAggregatedSize() throws {
        let a = dir("A", [file("a1", 100), file("a2", 200)])  // 300
        let b = file("B", 50)
        let root = dir("/root", [a, b])                        // 350

        try TreeEditor.remove(a, keeping: root)

        XCTAssertEqual(root.allocatedSize, 50)
        XCTAssertEqual(root.children!.map(\.name), ["B"])
        XCTAssertNil(a.parent)
    }

    func testRemoveNestedDirectoryUpdatesAllAncestors() throws {
        let leaf = file("leaf", 500)
        let inner = dir("inner", [leaf])               // 500
        let mid = dir("mid", [inner, file("m", 100)])  // 600
        let root = dir("/root", [mid, file("r", 40)])  // 640

        try TreeEditor.remove(inner, keeping: root)

        XCTAssertEqual(mid.allocatedSize, 100)
        XCTAssertEqual(root.allocatedSize, 140)
    }

    // MARK: - Guards

    func testRemovingFocusIsRejected() {
        let a = dir("A", [file("a1", 100)])
        let root = dir("/root", [a])

        XCTAssertThrowsError(try TreeEditor.remove(a, keeping: a)) { error in
            XCTAssertEqual(error as? TreeEditError, .cannotRemoveFocus)
        }
        XCTAssertEqual(root.allocatedSize, 100, "tree must be unchanged after a rejected removal")
    }

    func testRemovingRootIsRejected() {
        let a = dir("A", [file("a1", 100)])
        let root = dir("/root", [a])

        XCTAssertThrowsError(try TreeEditor.remove(root, keeping: a)) { error in
            XCTAssertEqual(error as? TreeEditError, .cannotRemoveRoot)
        }
    }

    func testRemovingDetachedNodeIsRejected() {
        let a = dir("A", [file("a1", 100)])
        let root = dir("/root", [a])
        let orphan = file("orphan", 10)
        orphan.parent = a  // parent set, but never added to a.children

        XCTAssertThrowsError(try TreeEditor.remove(orphan, keeping: root)) { error in
            XCTAssertEqual(error as? TreeEditError, .nodeNotInTree)
        }
        XCTAssertEqual(root.allocatedSize, 100, "tree must be unchanged after a rejected removal")
    }

    // MARK: - Trash integration (cleans up after itself)

    func testTrashItemMovesFileAndCanBeCleanedUp() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("StackdustTrash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("trashme.bin")
        try Data(repeating: 0xCD, count: 10_000).write(to: target)

        var trashedURL: NSURL?
        do {
            try FileManager.default.trashItem(at: target, resultingItemURL: &trashedURL)
        } catch {
            throw XCTSkip("Trash is unavailable in this environment: \(error.localizedDescription)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path),
                       "the original must be gone after trashing")

        if let trashed = trashedURL as URL? {
            XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path),
                          "the item should now live in the Trash")
            // Remove it from the Trash so the test leaves nothing behind.
            try? FileManager.default.removeItem(at: trashed)
        } else {
            XCTFail("trashItem did not report a resulting URL")
        }
    }
}
