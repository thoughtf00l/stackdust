import Foundation

/// A throttled snapshot of scan progress.
public struct ScanProgress: Sendable, Equatable {
    /// Number of directory entries visited so far (files, directories, symlinks, ...).
    public var itemsScanned: Int
    /// Running total of counted physical bytes so far (hard links counted once).
    public var bytesAccumulated: Int64
    /// Absolute path of the directory most recently started.
    public var currentPath: String

    public init(itemsScanned: Int, bytesAccumulated: Int64, currentPath: String) {
        self.itemsScanned = itemsScanned
        self.bytesAccumulated = bytesAccumulated
        self.currentPath = currentPath
    }
}

/// An update emitted by `DiskScanner.scan(at:)`.
///
/// The stream emits `.started` first (exactly once), then `.progress` repeatedly (throttled),
/// `.partial` repeatedly (throttled), and exactly one terminal `.finished` carrying the fully
/// built, size-aggregated tree, after which it finishes.
public enum ScanUpdate: Sendable {
    /// Emitted exactly once, before any other update: hands the consumer the `LiveScan` handle
    /// that steers the partial snapshots. The consumer writes its current focus path into the
    /// handle and each subsequent `.partial` follows that focus.
    case started(LiveScan)
    case progress(ScanProgress)
    /// A throttled, detached copy of the top of the in-progress tree; its `allocatedSize` values
    /// are partial lower bounds (they only grow) and the node identities are NOT those of the
    /// final tree carried by `.finished`.
    case partial(FileNode)
    case finished(FileNode)
}

/// Errors thrown by the scan engine.
enum ScanError: Error, Equatable {
    /// The scan root could not be accessed (does not exist, not a directory, or `stat` failed).
    case cannotAccessRoot(path: String, errno: Int32)
}
