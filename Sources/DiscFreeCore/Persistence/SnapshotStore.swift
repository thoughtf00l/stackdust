import CryptoKit
import Foundation

/// On-disk storage for scan snapshots, one file per scanned root.
///
/// Files live in `~/Library/Caches/DiscFree` (injectable for tests), named by a hash of the
/// root path so any root maps to a stable file. Cache semantics are deliberate: the system
/// may purge the directory at any time, and every consumer must treat a missing or corrupted
/// snapshot as "no cache" and fall back to a full scan.
public struct SnapshotStore: Sendable {

    /// One stored snapshot: its decoded header and the file it came from.
    public struct Entry: Sendable {
        public let header: SnapshotHeader
        public let fileURL: URL
    }

    public let directory: URL

    private static let fileExtension = "dfsnap"

    /// - Parameter directory: storage location; defaults to the user's caches directory
    ///   (`~/Library/Caches/DiscFree`).
    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            self.directory = caches.appendingPathComponent("DiscFree", isDirectory: true)
        }
    }

    /// Serializes `root` and writes it atomically, replacing any previous snapshot of the
    /// same root path.
    public func save(_ root: FileNode, scanDate: Date) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = TreeSnapshot.encode(root, scanDate: scanDate)
        try data.write(to: fileURL(forRootPath: root.name), options: .atomic)
    }

    /// All readable snapshots, newest scan first. Unreadable or corrupted files are skipped
    /// (cache semantics), never surfaced as errors.
    public func entries() -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []

        return files
            .filter { $0.pathExtension == Self.fileExtension }
            .compactMap { url -> Entry? in
                guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
                      let header = try? TreeSnapshot.decodeHeader(data) else { return nil }
                return Entry(header: header, fileURL: url)
            }
            .sorted { $0.header.scanDate > $1.header.scanDate }
    }

    /// The snapshot with the newest scan date, if any.
    public func mostRecent() -> Entry? {
        entries().first
    }

    /// Decodes the full tree for `entry`. Throws `SnapshotError` if the file was corrupted
    /// or removed since `entries()` listed it.
    public func loadTree(_ entry: Entry) throws -> FileNode {
        let data = try Data(contentsOf: entry.fileURL, options: .alwaysMapped)
        return try TreeSnapshot.decode(data).root
    }

    private func fileURL(forRootPath rootPath: String) -> URL {
        let digest = SHA256.hash(data: Data(rootPath.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined().prefix(32)
        return directory.appendingPathComponent("\(name).\(Self.fileExtension)")
    }
}
