import Foundation

/// The process exit-code taxonomy shared by every `stackdust` subcommand.
///
/// Values are stable and documented in the root command's `--help`; agents branch on them.
/// `1` (a generic failure) is deliberately absent: every anticipated failure maps to one of
/// these buckets, and an unexpected error surfacing as `1` signals a bug rather than a
/// documented condition.
enum ExitCategory: Int32 {
    /// Everything succeeded. Partial data (e.g. some unreadable directories) still counts.
    case success = 0
    /// The invocation itself was wrong: bad flag value, unknown category, non-directory path.
    case usageError = 2
    /// The requested path does not exist.
    case pathNotFound = 3
    /// A path exists but could not be read; for a scan root this usually means Full Disk Access.
    case permissionDenied = 4
    /// The operation ran but some clean operations failed (see the result's `failed` array).
    case partialFailure = 5
}
