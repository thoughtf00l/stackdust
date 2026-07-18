import ArgumentParser
import StackdustCore
import Foundation

extension Stackdust {
    /// `stackdust scan <path>` — scan a directory and print a bounded, largest-first tree.
    struct Scan: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Scan a directory and report its largest contents as a tree.",
            discussion: """
            Output is bounded by --depth, --top, and --min-size; when anything is dropped the \
            result is marked "truncated": true and a hint is printed to stderr.

            Example:
              stackdust scan ~/Library --depth 2 --top 10 --min-size 100M --json
            """
        )

        @Argument(help: "Directory to scan.")
        var path: String

        @Flag(name: .long, help: "Emit machine-readable JSON on stdout.")
        var json = false

        @Option(name: .long, help: "Levels of children to include below the root (0 = root only).")
        var depth: Int = 2

        @Option(name: .long, help: "Keep only the N largest children per directory.")
        var top: Int = 20

        @Option(name: .customLong("min-size"), help: "Drop entries smaller than SIZE (e.g. 500M, 1.5G).")
        var minSize: String?

        func run() async throws {
            try await runCommand(json: json) {
                try await execute()
            }
        }

        private func execute() async throws {
            let minBytes = try parseMinSize(minSize)
            guard depth >= 0 else {
                throw CLIError(code: "invalid_argument", message: "--depth must be >= 0.", exit: .usageError)
            }
            guard top >= 0 else {
                throw CLIError(code: "invalid_argument", message: "--top must be >= 0.", exit: .usageError)
            }

            let tree = try await ScanRunner.run(path: path)
            let unreadableCount = TreeShaper.countUnreadable(tree)
            let cloudEvictedCount = TreeShaper.countCloudEvicted(tree)
            let shaped = TreeShaper.shape(
                tree,
                options: .init(maxDepth: depth, top: top, minSize: minBytes)
            )

            let result = ScanResultDTO(
                path: tree.name,
                total_bytes: tree.allocatedSize,
                unreadable_count: unreadableCount,
                cloud_evicted_count: cloudEvictedCount,
                truncated: shaped.truncated,
                tree: shaped.node
            )

            if json {
                Output.line(try Output.json(result))
            } else {
                Output.line(HumanTables.tree(shaped.node))
                if unreadableCount > 0 {
                    Output.note("note: \(unreadableCount) item(s) could not be read and count as 0 bytes.")
                }
                if cloudEvictedCount > 0 {
                    Output.note("note: \(cloudEvictedCount) item(s) are evicted to iCloud, were not downloaded, and count as 0 bytes.")
                }
            }

            if shaped.truncated {
                Output.note(
                    "note: output truncated; widen with --depth, raise --top, or lower --min-size to see more."
                )
            }
        }
    }
}

/// Parses an optional `--min-size` string into bytes, mapping a parse failure to a usage error.
func parseMinSize(_ raw: String?) throws -> Int64 {
    guard let raw else { return 0 }
    do {
        return try ByteSize.parse(raw)
    } catch {
        throw CLIError(
            code: "invalid_argument",
            message: "Invalid --min-size '\(raw)'. Use bytes or a K/M/G/T suffix (e.g. 500M, 1.5G).",
            exit: .usageError
        )
    }
}
