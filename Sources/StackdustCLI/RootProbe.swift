import Darwin
import Foundation

/// Validates a scan-root path *before* scanning so the CLI can report a precise machine code
/// and exit status.
///
/// The core `DiskScanner` collapses several failure modes (missing path, a file instead of a
/// directory, an unreadable directory) into the same result, and its error type is not public.
/// Probing here with `stat(2)` separates "does not exist" from "not a directory" from
/// "cannot search the parent". A directory that exists but cannot be *opened* (the Full Disk
/// Access case) is detected after the scan via the root node's `isUnreadable` flag, not here.
enum RootProbe {

    /// Validates `path` and returns the standardized URL to scan (matching how `DiskScanner`
    /// normalises its root). Throws a `CLIError` for any problem.
    static func validate(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let resolvedPath = url.path

        var info = stat()
        if stat(resolvedPath, &info) != 0 {
            let code = errno
            switch code {
            case ENOENT:
                throw CLIError(
                    code: "path_not_found",
                    message: "No such file or directory.",
                    path: resolvedPath,
                    exit: .pathNotFound
                )
            case ENOTDIR:
                throw CLIError(
                    code: "not_a_directory",
                    message: "A component of the path is not a directory.",
                    path: resolvedPath,
                    exit: .usageError
                )
            case EACCES, EPERM:
                throw CLIError(
                    code: "permission_denied",
                    message: "Permission denied.",
                    path: resolvedPath,
                    hint: fullDiskAccessHint,
                    exit: .permissionDenied
                )
            default:
                throw CLIError(
                    code: "path_not_found",
                    message: String(cString: strerror(code)),
                    path: resolvedPath,
                    exit: .pathNotFound
                )
            }
        }

        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw CLIError(
                code: "not_a_directory",
                message: "Path is not a directory.",
                path: resolvedPath,
                exit: .usageError
            )
        }

        return url
    }
}
