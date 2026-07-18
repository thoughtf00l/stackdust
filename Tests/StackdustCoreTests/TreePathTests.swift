import XCTest
@testable import StackdustCore

final class TreePathTests: XCTestCase {

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

    func testComponentsOfRootIsEmpty() {
        let root = dir("/root", [])
        XCTAssertEqual(TreePath.components(of: root), [])
    }

    func testComponentsAndResolveRoundTrip() {
        let deep = file("file.bin", 1)
        let sub = dir("sub", [deep])
        let root = dir("/root", [dir("a", [sub])])

        let components = TreePath.components(of: deep)
        XCTAssertEqual(components, ["a", "sub", "file.bin"])
        XCTAssertTrue(TreePath.resolve(components, in: root) === deep)
    }

    func testResolveInReplacementTreeFindsSameNamedNode() {
        let oldSub = dir("sub", [])
        let oldRoot = dir("/root", [dir("a", [oldSub])])
        let newSub = dir("sub", [file("added.bin", 5)])
        let newRoot = dir("/root", [dir("a", [newSub]), dir("b", [])])

        let components = TreePath.components(of: oldSub)
        XCTAssertTrue(TreePath.resolve(components, in: oldRoot) === oldSub)
        XCTAssertTrue(TreePath.resolve(components, in: newRoot) === newSub)
    }

    func testResolveClimbsToNearestSurvivingAncestor() {
        let a = dir("a", [])
        let root = dir("/root", [a])

        XCTAssertTrue(TreePath.resolve(["a", "vanished", "deeper"], in: root) === a)
        XCTAssertTrue(TreePath.resolve(["gone-entirely"], in: root) === root)
    }
}
