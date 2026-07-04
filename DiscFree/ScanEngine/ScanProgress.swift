import Foundation

/// A throttled snapshot of scan progress.
struct ScanProgress: Sendable, Equatable {
    /// Number of directory entries visited so far (files, directories, symlinks, ...).
    var itemsScanned: Int
    /// Running total of counted physical bytes so far (hard links counted once).
    var bytesAccumulated: Int64
    /// Absolute path of the directory most recently started.
    var currentPath: String
}

/// An update emitted by `DiskScanner.scan(at:)`.
///
/// The stream emits `.progress` repeatedly (throttled) and exactly one terminal
/// `.finished` carrying the fully built, size-aggregated tree, after which it finishes.
enum ScanUpdate: Sendable {
    case progress(ScanProgress)
    case finished(FileNode)
}

/// Errors thrown by the scan engine.
enum ScanError: Error, Equatable {
    /// The scan root could not be accessed (does not exist, not a directory, or `stat` failed).
    case cannotAccessRoot(path: String, errno: Int32)
}
