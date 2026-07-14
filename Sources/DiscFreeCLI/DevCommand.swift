import ArgumentParser
import DiscFreeCore
import Foundation

extension DiscFree {
    /// `discfree dev <path>` — scan, classify, and list reclaimable item roots.
    struct Dev: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List reclaimable items (build/package caches, app caches, logs, iOS backups, Adobe media caches, ...).",
            discussion: """
            Reports only the roots of reclaimable items (e.g. a whole node_modules or app cache \
            folder), never the files inside them, sorted largest-first.

            Example:
              discfree dev ~ --min-size 100M --json
            """
        )

        @Argument(help: "Directory to scan.")
        var path: String

        @Flag(name: .long, help: "Emit machine-readable JSON on stdout.")
        var json = false

        @Option(name: .customLong("min-size"), help: "Only list items at least SIZE (e.g. 500M, 1.5G).")
        var minSize: String?

        func run() async throws {
            try await runCommand(json: json) {
                try await execute()
            }
        }

        private func execute() async throws {
            let minBytes = try parseMinSize(minSize)

            let tree = try await ScanRunner.run(path: path)
            DevClassifier.classify(tree, using: DevItemCatalog())

            let items = DevSelection.filter(
                DevSelection.collect(tree),
                categories: nil,
                minSize: minBytes
            )
            let dtos = items.map { DevItemDTO(path: $0.path, category: $0.category.rawValue, bytes: $0.bytes) }
            let total = dtos.reduce(Int64(0)) { $0 + $1.bytes }

            if json {
                Output.line(try Output.json(DevResultDTO(items: dtos, total_bytes: total)))
            } else {
                Output.line(HumanTables.devItems(dtos, totalBytes: total))
            }
        }
    }
}
