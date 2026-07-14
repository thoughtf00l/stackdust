# DiscFree

A macOS disk-space analyzer: a GUI app (sunburst chart, safe Move-to-Trash) and an
agent-friendly CLI (`discfree`) sharing one core (`DiscFreeCore`). The CLI is designed
for AI coding agents as first-class users: JSON output, stable exit codes, never
interactive, never deletes permanently.

## Repository layout

- `Sources/DiscFreeCore/` — shared core: parallel disk scanner (`DiskScanner` →
  `FileNode` tree), dev-item rules (`DevItemCatalog`), classification
  (`DevClassifier`), tree mutation (`TreeEditor`).
- `Sources/DiscFreeCLI/` — all CLI command logic (library, unit-tested).
- `Sources/discfree/` — thin CLI executable entry point.
- `DiscFree/` — the macOS app (SwiftUI); built by `DiscFree.xcodeproj`, consumes the
  local package.
- `Tests/` — package tests (core + CLI). `DiscFreeTests/` — app/UI tests.

## Build and test

```sh
swift build                       # package: core + CLI
swift test                        # package tests
swift run discfree --help        # run the CLI from source
xcodebuild -project DiscFree.xcodeproj -scheme DiscFree -configuration Debug build   # app
xcodebuild test -project DiscFree.xcodeproj -scheme DiscFree -destination 'platform=macOS'  # app tests
```

The built CLI binary lands at `.build/debug/discfree`.

## Conventions for working on this repo

- All code, comments, commit messages, and UI strings are English-only.
- The package pins the Swift 5 language mode (`swiftLanguageMode(.v5)`); do not
  migrate files to Swift 6 strict concurrency as a side effect of other changes.
- `FileNode` trees can have millions of nodes: never call `FileNode.path` (an
  O(depth) string rebuild) inside a whole-tree walk — thread the path or context
  down the recursion (see `DevClassifier.classify`).
- Deletion anywhere in the project means `FileManager.trashItem` (recoverable),
  never `removeItem`.
- Before claiming a change works, run the builds and tests above.

## Using the `discfree` CLI (for agents)

General contract:

- Primary data → stdout. Progress, notes, and errors → stderr. `--json` on any
  subcommand makes stdout a single-line JSON object and errors a JSON object on
  stderr: `{"error": "<machine_code>", "message": "...", "path"?: "...", "hint"?: "..."}`.
  Machine codes: `path_not_found`, `not_a_directory`, `permission_denied`,
  `invalid_argument`, `partial_failure`, `scan_failed`.
- Never prompts, never reads stdin. Progress renders only when stderr is a TTY.
- Output is bounded by default; a `truncated: true` field plus a stderr hint tell
  you when narrowing flags hid data.
- SIZE values are decimal: `500M` = 500,000,000; `K`/`M`/`G`/`T`, fractions allowed
  (`1.5G`).

Exit codes:

| Code | Meaning |
|------|---------|
| 0 | success (partial data — e.g. some unreadable subdirectories — still counts) |
| 2 | usage error: bad flag value, unknown category, path is not a directory |
| 3 | path not found |
| 4 | permission denied on the scan root (likely Full Disk Access, see below) |
| 5 | partial failure: some `clean --yes` operations failed |

### `discfree scan <path> [--json] [--depth N] [--top N] [--min-size SIZE]`

Disk usage as a size-sorted tree. Defaults: `--depth 2`, `--top 20` children per
directory. JSON shape:

```json
{"path": "...", "total_bytes": 0, "unreadable_count": 0, "truncated": false,
 "tree": {"name": "...", "bytes": 0, "dir": true, "unreadable": true, "children": []}}
```

`bytes` is physical size on disk; hard links count once (a second occurrence shows
0 bytes). A directory reachable at several paths (APFS firmlinks, e.g. `/Users` vs
`/System/Volumes/Data/Users`) is likewise counted once, with later occurrences shown
as empty directories. `unreadable` is present only when true.

### `discfree dev <path> [--json] [--min-size SIZE]`

Reclaimable items (Xcode DerivedData/Archives/DeviceSupport, simulators,
package-manager caches, `node_modules`, Rust `target` next to a `Cargo.toml`,
Android AVDs and SDK system images, Gradle wrapper, Docker VM disks, per-app caches
under `~/Library/Caches`, `~/Library/Logs`, local iOS device backups, Adobe media
caches, ...), largest first. Categories: `xcodeBuild`, `xcodeArchives`,
`deviceSupport`, `simulators`, `packageCache`, `projectArtifacts`, `docker`,
`appCaches`, `logs`, `iosBackups`, `adobeCache`. Xcode Archives are a separate
category from `xcodeBuild` because they hold released builds' dSYMs and cannot be
regenerated, so `clean --category xcodeBuild` never selects them. `deviceSupport`
reports each `~/Library/Developer/Xcode/<platform> DeviceSupport` entry per
device/OS version (not the whole folder) and is its own category, out of `xcodeBuild`,
because Xcode copies those symbols off a connected device and cannot regenerate them
without a device running that OS version. `appCaches` reports each app's
folder under `~/Library/Caches` as its own item (folders already covered by a more
specific category, e.g. Xcode or SwiftPM caches, keep that category instead), so a
caller can reclaim individual apps rather than the whole caches directory. JSON:
`{"items": [{"path", "category", "risk", "bytes"}], "total_bytes"}`.

`risk` is the category's risk tier as a snake_case token: `safe` (regenerated at no
cost beyond build time — `xcodeBuild`, `logs`), `costs_time` (comes back on demand,
paying network and time — `packageCache`, `projectArtifacts`, `appCaches`,
`adobeCache`, `deviceSupport`), or `loses_state` (trashing destroys non-reproducible state —
`simulators`, `xcodeArchives`, `docker`, `iosBackups`). The human (non-JSON) output
groups items under a per-category header (`displayName — total [risk]`), largest
category first.

### `discfree clean <path> [--json] [--category c1,c2] [--min-size SIZE] [--yes] [--dry-run]`

Safety contract:

- Without `--yes` (or with `--dry-run`): prints the plan and exits 0 — nothing is
  touched. JSON: `{"dry_run": true, "planned": [{"path", "category", "risk",
  "bytes"}], "total_bytes", "hint"}`.
- With `--yes`: moves the selected items to the **Trash** (recoverable), never
  unlinks. JSON: `{"dry_run": false, "trashed": [{"path", "category", "risk",
  "bytes", "note"?}], "failed": [{"path", "message"}], "reclaimed_bytes"}`.
  `planned` and `trashed` items carry the same `risk` token as `dev` items; `failed`
  items do not (they carry only `path` and `message`).
- Only items the classifier marked as dev items can ever be selected.
- Idempotent: a path that vanished between scan and trash is reported with
  `"note": "already gone"` and does not fail the run.

Acting on `risk`: items with `risk: "safe"` or `"costs_time"` may be cleaned
autonomously when they meet the user's size goal — they cost at most build time or a
re-download. Items with `"loses_state"` (simulators, Docker VM disks, Xcode archives,
iOS device backups) destroy state that cannot be reproduced; propose these to the
human and clean them only after explicit confirmation.

Recommended agent flow: `dev --json` → decide → `clean --category ... --min-size ...`
(review the plan) → same command with `--yes`.

### Full Disk Access (macOS TCC)

Reading protected locations (`~/Library`, Desktop, Documents, ...) requires Full
Disk Access for the **terminal app** the CLI runs in, not for `discfree` itself.
On a permission failure the CLI exits 4 with a structured hint. Grant it in
System Settings → Privacy & Security → Full Disk Access, then restart the terminal.
Scanning unprotected paths needs no setup.
