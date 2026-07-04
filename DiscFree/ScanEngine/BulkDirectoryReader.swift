import Darwin
import Foundation

/// Parsed attributes for a single directory entry returned by `getattrlistbulk(2)`.
///
/// Only the attributes actually returned for the entry are marked present (`has*`),
/// because `getattrlistbulk` omits attributes that do not apply to an entry's type
/// (e.g. `ATTR_FILE_*` is absent for directories and symlinks).
struct BulkEntry {
    var recordLength: Int = 0
    var error: UInt32 = 0
    var name: String = ""
    var hasName = false
    var devID: dev_t = 0
    var hasDevID = false
    var objType: UInt32 = 0
    var hasObjType = false
    var fileID: UInt64 = 0
    var hasFileID = false
    var linkCount: UInt32 = 0
    var hasLinkCount = false
    var allocatedSize: Int64 = 0
    var hasAllocatedSize = false
}

/// Wraps a `getattrlistbulk(2)` traversal of one open directory.
///
/// The attribute layout inside the buffer is fixed by the kernel: a leading `uint32_t`
/// record length, then `ATTR_CMN_RETURNED_ATTRS` (an `attribute_set_t`), then
/// `ATTR_CMN_ERROR` (documented to come immediately after the returned set), then the
/// remaining common attributes in ascending bit order, then the file-group attributes in
/// ascending bit order. Only attributes flagged in the returned set are present.
///
/// All multi-byte fields are read with `loadUnaligned` because `getattrlist` packs values
/// at 4-byte alignment, so 8-byte values may not be naturally aligned.
enum BulkDirectoryReader {
    /// The request bitmap shared by every enumeration.
    static func makeAttrList() -> attrlist {
        var attrs = attrlist()
        attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = attrgroup_t(
            UInt32(ATTR_CMN_RETURNED_ATTRS)
                | UInt32(ATTR_CMN_NAME)
                | UInt32(ATTR_CMN_DEVID)
                | UInt32(ATTR_CMN_OBJTYPE)
                | UInt32(ATTR_CMN_FILEID)
                | UInt32(ATTR_CMN_ERROR)
        )
        attrs.fileattr = attrgroup_t(
            UInt32(ATTR_FILE_LINKCOUNT) | UInt32(ATTR_FILE_ALLOCSIZE)
        )
        return attrs
    }

    /// Parses one entry starting at `base`. Caller advances by `recordLength` to the next.
    static func parse(_ base: UnsafeRawPointer) -> BulkEntry {
        var entry = BulkEntry()
        var offset = 0

        entry.recordLength = Int(base.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        offset += MemoryLayout<UInt32>.size

        // attribute_set_t = { commonattr, volattr, dirattr, fileattr, forkattr } (5 x UInt32).
        let commonReturned = base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        let fileReturned = base.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self)
        offset += MemoryLayout<attribute_set_t>.size

        // ATTR_CMN_ERROR is placed immediately after the returned-attrs set.
        if commonReturned & UInt32(ATTR_CMN_ERROR) != 0 {
            entry.error = base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            offset += MemoryLayout<UInt32>.size
        }

        // ATTR_CMN_NAME: attrreference_t { attr_dataoffset (Int32), attr_length (UInt32) };
        // the name bytes live at (field address + attr_dataoffset), NUL-terminated.
        if commonReturned & UInt32(ATTR_CMN_NAME) != 0 {
            let dataOffset = base.loadUnaligned(fromByteOffset: offset, as: Int32.self)
            let namePtr = base.advanced(by: offset + Int(dataOffset))
            entry.name = String(cString: namePtr.assumingMemoryBound(to: CChar.self))
            entry.hasName = true
            offset += MemoryLayout<attrreference_t>.size
        }

        if commonReturned & UInt32(ATTR_CMN_DEVID) != 0 {
            entry.devID = base.loadUnaligned(fromByteOffset: offset, as: dev_t.self)
            entry.hasDevID = true
            offset += MemoryLayout<dev_t>.size
        }

        if commonReturned & UInt32(ATTR_CMN_OBJTYPE) != 0 {
            entry.objType = base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            entry.hasObjType = true
            offset += MemoryLayout<fsobj_type_t>.size
        }

        if commonReturned & UInt32(ATTR_CMN_FILEID) != 0 {
            entry.fileID = base.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            entry.hasFileID = true
            offset += MemoryLayout<UInt64>.size
        }

        if fileReturned & UInt32(ATTR_FILE_LINKCOUNT) != 0 {
            entry.linkCount = base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            entry.hasLinkCount = true
            offset += MemoryLayout<UInt32>.size
        }

        if fileReturned & UInt32(ATTR_FILE_ALLOCSIZE) != 0 {
            entry.allocatedSize = base.loadUnaligned(fromByteOffset: offset, as: Int64.self)
            entry.hasAllocatedSize = true
            offset += MemoryLayout<Int64>.size
        }

        return entry
    }
}
