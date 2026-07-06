import Foundation

/// Thrown when snapshot data cannot be decoded.
public enum SnapshotError: Error, Equatable {
    /// The data is not a snapshot or is damaged/truncated.
    case corrupted
    /// The data is a snapshot written by a newer, unknown format version.
    case unsupportedVersion(UInt8)
}

/// The metadata stored at the front of a snapshot, decodable without reading the tree.
public struct SnapshotHeader: Sendable, Equatable {
    /// Absolute path of the scanned root (matches the root node's `name`).
    public let rootPath: String
    /// When the scan that produced the tree finished.
    public let scanDate: Date
    /// The root's `allocatedSize` at save time, kept in the header so callers can show
    /// totals (and estimate rescan progress) without decoding millions of nodes.
    public let totalBytes: Int64
}

/// Binary serialization of a scanned `FileNode` tree.
///
/// Trees can hold millions of nodes, so the format is a compact hand-rolled stream rather
/// than `Codable`: a fixed header, then the nodes depth-first — name (varint length + UTF-8),
/// a flags byte (directory, unreadable), `allocatedSize` as a varint, and for directories a
/// child count followed by the children. `devSize`/`devCategory` are deliberately not
/// persisted: classification is a single cheap pass that must be re-run after loading anyway
/// (the catalog rules may have changed between runs).
public enum TreeSnapshot {

    private static let magic: [UInt8] = Array("DFSN".utf8)
    private static let version: UInt8 = 1

    private struct Flags {
        static let isDirectory: UInt8 = 1 << 0
        static let isUnreadable: UInt8 = 1 << 1
    }

    // MARK: - Encoding

    /// Serializes `root` (and the scan metadata) into snapshot data.
    public static func encode(_ root: FileNode, scanDate: Date) -> Data {
        var out: [UInt8] = []
        out.reserveCapacity(1 << 20)

        out.append(contentsOf: magic)
        out.append(version)
        appendUInt64(scanDate.timeIntervalSince1970.bitPattern, to: &out)
        appendString(root.name, to: &out)
        appendVarint(UInt64(root.allocatedSize), to: &out)

        appendNode(root, to: &out)
        return Data(out)
    }

    private static func appendNode(_ node: FileNode, to out: inout [UInt8]) {
        appendString(node.name, to: &out)

        var flags: UInt8 = 0
        if node.isDirectory { flags |= Flags.isDirectory }
        if node.isUnreadable { flags |= Flags.isUnreadable }
        out.append(flags)

        appendVarint(UInt64(node.allocatedSize), to: &out)

        if let children = node.children {
            appendVarint(UInt64(children.count), to: &out)
            for child in children {
                appendNode(child, to: &out)
            }
        }
    }

    // MARK: - Decoding

    /// Decodes only the header — cheap even for snapshots holding millions of nodes.
    public static func decodeHeader(_ data: Data) throws -> SnapshotHeader {
        var reader = Reader(data: data)
        return try readHeader(&reader)
    }

    /// Decodes the full snapshot: the header and the reconstructed tree (parent links
    /// restored, `devSize`/`devCategory` left at their defaults pending a classify pass).
    public static func decode(_ data: Data) throws -> (header: SnapshotHeader, root: FileNode) {
        var reader = Reader(data: data)
        let header = try readHeader(&reader)
        let root = try readNode(&reader, parent: nil)
        guard root.name == header.rootPath, root.isDirectory else { throw SnapshotError.corrupted }
        return (header, root)
    }

    private static func readHeader(_ reader: inout Reader) throws -> SnapshotHeader {
        guard try reader.readBytes(magic.count).elementsEqual(magic) else {
            throw SnapshotError.corrupted
        }
        let fileVersion = try reader.readByte()
        guard fileVersion == version else { throw SnapshotError.unsupportedVersion(fileVersion) }

        let dateBits = try reader.readUInt64()
        let interval = TimeInterval(bitPattern: dateBits)
        guard interval.isFinite else { throw SnapshotError.corrupted }

        let rootPath = try reader.readString()
        let totalBytes = try reader.readSize()
        return SnapshotHeader(
            rootPath: rootPath,
            scanDate: Date(timeIntervalSince1970: interval),
            totalBytes: totalBytes
        )
    }

    private static func readNode(_ reader: inout Reader, parent: FileNode?) throws -> FileNode {
        let name = try reader.readString()
        let flags = try reader.readByte()
        let size = try reader.readSize()

        let node = FileNode(
            name: name,
            isDirectory: flags & Flags.isDirectory != 0,
            allocatedSize: size,
            parent: parent
        )
        node.isUnreadable = flags & Flags.isUnreadable != 0

        if node.isDirectory {
            let count = try reader.readVarint()
            // A count that cannot possibly fit in the remaining bytes means damage; checking
            // here keeps a corrupted count from turning into a huge reserveCapacity.
            guard count <= UInt64(reader.remaining) else { throw SnapshotError.corrupted }
            var children: [FileNode] = []
            children.reserveCapacity(Int(count))
            for _ in 0..<count {
                children.append(try readNode(&reader, parent: node))
            }
            node.children = children
        }
        return node
    }

    // MARK: - Primitives

    private static func appendVarint(_ value: UInt64, to out: inout [UInt8]) {
        var v = value
        while v >= 0x80 {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
    }

    private static func appendUInt64(_ value: UInt64, to out: inout [UInt8]) {
        for shift in stride(from: 0, to: 64, by: 8) {
            out.append(UInt8((value >> shift) & 0xFF))
        }
    }

    private static func appendString(_ string: String, to out: inout [UInt8]) {
        let bytes = Array(string.utf8)
        appendVarint(UInt64(bytes.count), to: &out)
        out.append(contentsOf: bytes)
    }

    /// Bounds-checked sequential reader; any overrun throws `.corrupted`.
    private struct Reader {
        private let data: [UInt8]
        private var index = 0

        init(data: Data) {
            self.data = [UInt8](data)
        }

        var remaining: Int { data.count - index }

        mutating func readByte() throws -> UInt8 {
            guard index < data.count else { throw SnapshotError.corrupted }
            defer { index += 1 }
            return data[index]
        }

        mutating func readBytes(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, index + count <= data.count else { throw SnapshotError.corrupted }
            defer { index += count }
            return data[index..<index + count]
        }

        mutating func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard shift < 64 else { throw SnapshotError.corrupted }
                let byte = try readByte()
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
        }

        /// A varint that must fit a non-negative `Int64` (all sizes in the format).
        mutating func readSize() throws -> Int64 {
            let raw = try readVarint()
            guard raw <= UInt64(Int64.max) else { throw SnapshotError.corrupted }
            return Int64(raw)
        }

        mutating func readUInt64() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, to: 64, by: 8) {
                value |= UInt64(try readByte()) << shift
            }
            return value
        }

        mutating func readString() throws -> String {
            let length = try readVarint()
            guard length <= UInt64(remaining) else { throw SnapshotError.corrupted }
            return String(decoding: try readBytes(Int(length)), as: UTF8.self)
        }
    }
}
