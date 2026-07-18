import XCTest
@testable import StackdustCore

/// Synthetic `FileNode` builders for CLI tests. Mirrors the helpers in DevClassifierTests;
/// no disk is touched. Requires `@testable import StackdustCore` for the internal initialiser
/// and the `internal(set)` fields.
enum TreeFixtures {
    static func file(_ name: String, _ size: Int64) -> FileNode {
        FileNode(name: name, isDirectory: false, allocatedSize: size, parent: nil)
    }

    static func dir(_ name: String, _ children: [FileNode]) -> FileNode {
        let node = FileNode(name: name, isDirectory: true, parent: nil)
        node.children = children
        for child in children { child.parent = node }
        node.allocatedSize = children.reduce(0) { $0 + $1.allocatedSize }
        return node
    }

    /// A directory that could not be read (no children, flagged unreadable).
    static func unreadableDir(_ name: String) -> FileNode {
        let node = FileNode(name: name, isDirectory: true, parent: nil)
        node.isUnreadable = true
        return node
    }

    /// A directory whose content is evicted to iCloud (no children, flagged cloud-evicted).
    static func cloudEvictedDir(_ name: String) -> FileNode {
        let node = FileNode(name: name, isDirectory: true, parent: nil)
        node.isCloudEvicted = true
        return node
    }
}
