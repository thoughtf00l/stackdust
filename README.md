# Stackdust

A macOS disk-space analyzer that knows what developer junk looks like.

Stackdust scans a folder (or the whole disk), shows where the space went as an
interactive sunburst chart, and highlights things that are safe to reclaim:
Xcode DerivedData, old simulators, package-manager caches, `node_modules`,
Rust `target` directories, Docker VM disks, and more. Cleanup always moves
items to the Trash — nothing is ever deleted permanently.

It ships in two forms sharing the same scanning core:

- **Stackdust.app** — a SwiftUI app with a sunburst chart, dev-junk highlighting,
  and one-click Move to Trash.
- **`stackdust` CLI** — built for AI coding agents and scripts: JSON output,
  stable exit codes, never interactive, same Trash-only safety contract.

## How this was built

This project was created by Claude, Anthropic's AI models — not written by a
human programmer. Claude Opus wrote the code and Claude Fable 5 reviewed and
committed it. The human in the loop, [@thoughtf00l](https://github.com/thoughtf00l),
provided the idea, high-level direction, and occasional course corrections,
but none of the code. The same applies to this README.

## Install

Requires macOS 15 (Sequoia) or later. The app is a universal binary
(Apple Silicon and Intel).

### Homebrew

```sh
brew tap thoughtf00l/tap
brew trust thoughtf00l/tap   # one-time, required by Homebrew 6+
brew install --cask stackdust
```

The app is not notarized; the cask clears the macOS quarantine flag on
install, so it opens without a Gatekeeper prompt.

### Manual download

Download [`Stackdust.dmg`](https://github.com/thoughtf00l/stackdust/releases/latest/download/Stackdust.dmg)
(or from [stackdust.app](https://stackdust.app)), open it, and drag Stackdust
to Applications. On first launch either allow the app in
System Settings → Privacy & Security → **Open Anyway**, or clear the
quarantine flag yourself:

```sh
xattr -d com.apple.quarantine /Applications/Stackdust.app
```

After that, the app keeps itself current: check from the app menu
(**Check for Updates…**) or let it check automatically.

### Build from source

Requires Xcode 16 or later.

```sh
git clone https://github.com/thoughtf00l/stackdust.git
cd stackdust

# The app
xcodebuild -project Stackdust.xcodeproj -scheme Stackdust -configuration Release build

# The CLI
swift build -c release   # binary lands at .build/release/stackdust
```

## Full Disk Access

Scanning protected locations (`~/Library`, Desktop, Documents, …) requires
Full Disk Access — grant it in System Settings → Privacy & Security →
Full Disk Access. For the CLI, grant it to the **terminal app** the CLI runs
in, not to `stackdust` itself. Scanning unprotected paths needs no setup.

## The `stackdust` CLI

```sh
stackdust scan ~/dev --json        # disk usage as a size-sorted tree
stackdust dev ~/dev --json         # developer-reclaimable items, largest first
stackdust clean ~/dev --category xcodeBuild --min-size 500M   # prints the plan, touches nothing
stackdust clean ~/dev --category xcodeBuild --min-size 500M --yes   # moves to Trash
```

Without `--yes`, `clean` only prints what it would do. With `--yes`, selected
items are moved to the Trash (recoverable), never unlinked. See
[AGENTS.md](AGENTS.md) for the full contract: JSON shapes, exit codes, and
the recommended agent workflow.

## Safety

- Deletion means `FileManager.trashItem` — everything goes to the Trash and
  can be put back.
- Only items the classifier recognized as developer artifacts can be selected
  for cleanup.
- The CLI never prompts and never reads stdin; without `--yes` it never
  modifies anything.

## License

[MIT](LICENSE)
