import Foundation

/// Locates nodes across two scans of the same root by their name path, so the UI can keep
/// its focus when a background rescan replaces the tree.
public enum TreePath {

    /// The chain of names from (but excluding) the root down to `node`. Empty when `node`
    /// is the root itself.
    public static func components(of node: FileNode) -> [String] {
        var names: [String] = []
        var current: FileNode? = node
        while let this = current, this.parent != nil {
            names.append(this.name)
            current = this.parent
        }
        return names.reversed()
    }

    /// Follows `components` down from `root` and returns the deepest node that still
    /// exists — the node itself when the whole path survives, otherwise its nearest
    /// surviving ancestor (possibly `root`).
    public static func resolve(_ components: [String], in root: FileNode) -> FileNode {
        var current = root
        for name in components {
            guard let child = current.children?.first(where: { $0.name == name }) else {
                return current
            }
            current = child
        }
        return current
    }
}
