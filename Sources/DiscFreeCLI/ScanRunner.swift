import DiscFreeCore
import Foundation

/// Drives a scan end to end: validate the root, consume the scanner's stream while reporting
/// progress, and return the aggregated tree. Shared by `scan`, `dev`, and `clean`.
enum ScanRunner {

    /// Validates `path`, scans it, and returns the root `FileNode`.
    ///
    /// - Throws: `CLIError` for a missing/invalid root (before scanning) or an unreadable root
    ///   (after scanning — the Full Disk Access case, detected via `isUnreadable`).
    static func run(path: String) async throws -> FileNode {
        let url = try RootProbe.validate(path)

        let scanner = DiskScanner()
        let progress = ProgressReporter()
        var tree: FileNode?

        do {
            for try await update in scanner.scan(at: url) {
                switch update {
                case .started:
                    break  // The CLI never navigates, so it does not steer partial snapshots.
                case .progress(let snapshot):
                    progress.report(snapshot)
                case .partial:
                    break  // The CLI has no live view; it uses only the final tree.
                case .finished(let root):
                    tree = root
                }
            }
        } catch {
            progress.finish()
            throw error
        }
        progress.finish()

        guard let tree else {
            throw CLIError(
                code: "scan_failed",
                message: "The scan produced no result.",
                path: url.path,
                exit: .permissionDenied
            )
        }

        // The root existed and was a directory at probe time, but the scanner could not open
        // it — on macOS this is almost always missing Full Disk Access for the terminal app.
        if tree.isUnreadable {
            throw CLIError(
                code: "permission_denied",
                message: "The scan root could not be read.",
                path: tree.name,
                hint: fullDiskAccessHint,
                exit: .permissionDenied
            )
        }

        return tree
    }
}
