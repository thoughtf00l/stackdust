import Foundation

/// The JSON models emitted on stdout. Structure is stable (key *order* is not guaranteed);
/// optional fields are omitted when nil. All are `Codable` so tests can round-trip them.

/// One node in a shaped scan tree.
///
/// `unreadable` is present only when the directory could not be read (a genuine failure).
/// `cloud_evicted` is present only when the directory's content is evicted to iCloud and was
/// intentionally not downloaded; the two are mutually exclusive. `children` is present for
/// directories (possibly empty when pruned or not descended into) and absent for files.
struct TreeNodeDTO: Codable, Equatable {
    let name: String
    let bytes: Int64
    let dir: Bool
    let unreadable: Bool?
    let cloud_evicted: Bool?
    let children: [TreeNodeDTO]?
}

/// The result of `stackdust scan`.
///
/// `unreadable_count` counts only genuine read failures; iCloud-evicted directories are counted
/// separately in `cloud_evicted_count` and are NOT included in `unreadable_count`.
struct ScanResultDTO: Codable, Equatable {
    let path: String
    let total_bytes: Int64
    let unreadable_count: Int
    let cloud_evicted_count: Int
    let truncated: Bool
    let tree: TreeNodeDTO
}

/// One developer-reclaimable item root, used by `dev` and `clean`.
///
/// `risk` is the category's risk tier as a snake_case token (`safe` / `costs_time` /
/// `loses_state`), matching this CLI's JSON key convention (e.g. `total_bytes`).
struct DevItemDTO: Codable, Equatable {
    let path: String
    let category: String
    let risk: String
    let bytes: Int64
}

/// The result of `stackdust dev`.
struct DevResultDTO: Codable, Equatable {
    let items: [DevItemDTO]
    let total_bytes: Int64
}

/// The result of `stackdust clean` without `--yes` (or with `--dry-run`): a plan only.
struct CleanPlanDTO: Codable, Equatable {
    let dry_run: Bool
    let planned: [DevItemDTO]
    let total_bytes: Int64
    let hint: String
}

/// One item that was moved to Trash (or found already gone).
///
/// `note` is present only for items that had already vanished between scan and trash; those
/// contribute nothing to `reclaimed_bytes` because this run did not move them.
struct TrashedItemDTO: Codable, Equatable {
    let path: String
    let category: String
    let risk: String
    let bytes: Int64
    let note: String?
}

/// One item that could not be trashed.
struct FailedItemDTO: Codable, Equatable {
    let path: String
    let message: String
}

/// The result of `stackdust clean --yes`.
struct CleanResultDTO: Codable, Equatable {
    let dry_run: Bool
    let trashed: [TrashedItemDTO]
    let failed: [FailedItemDTO]
    let reclaimed_bytes: Int64
}
