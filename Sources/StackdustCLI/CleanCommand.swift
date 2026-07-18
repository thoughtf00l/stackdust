import ArgumentParser
import StackdustCore
import Foundation

extension Stackdust {
    /// `stackdust clean <path>` — select reclaimable items and move them to Trash.
    ///
    /// Non-destructive by default: without `--yes` (or with `--dry-run`) it only prints the plan.
    /// It never deletes anything the classifier did not mark as a reclaimable item, and it uses
    /// the Trash rather than unlinking, so an action is recoverable and re-running is idempotent.
    struct Clean: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move reclaimable items to the Trash (opt-in, recoverable).",
            discussion: """
            By default this prints a plan and exits without touching anything. Pass --yes to \
            actually move the selected items to the Trash. Items are never deleted permanently.

            Example:
              stackdust clean ~ --category packageCache,xcodeBuild --min-size 500M --yes --json
            """
        )

        @Argument(help: "Directory to scan.")
        var path: String

        @Flag(name: .long, help: "Emit machine-readable JSON on stdout.")
        var json = false

        @Option(name: .long, help: "Restrict to these categories, comma-separated (\(Categories.validValuesList)).")
        var category: String?

        @Option(name: .customLong("min-size"), help: "Only act on items at least SIZE (e.g. 500M, 1.5G).")
        var minSize: String?

        @Flag(name: .long, help: "Actually move the selected items to the Trash.")
        var yes = false

        @Flag(name: .customLong("dry-run"), help: "Print the plan and exit, even with --yes.")
        var dryRun = false

        func run() async throws {
            try await runCommand(json: json) {
                try await execute()
            }
        }

        private func execute() async throws {
            let minBytes = try parseMinSize(minSize)
            let categories = try category.map { try Categories.parse($0) }

            let tree = try await ScanRunner.run(path: path)
            DevClassifier.classify(tree, using: DevItemCatalog())

            let planned = DevSelection.filter(
                DevSelection.collect(tree),
                categories: categories,
                minSize: minBytes
            )

            if !yes || dryRun {
                try emitPlan(planned)
                return
            }
            try trash(planned)
        }

        // MARK: - Plan (no --yes, or --dry-run)

        private func emitPlan(_ planned: [DevSelection.Item]) throws {
            let dtos = planned.map {
                DevItemDTO(
                    path: $0.path, category: $0.category.rawValue,
                    risk: $0.category.riskToken, bytes: $0.bytes
                )
            }
            let total = dtos.reduce(Int64(0)) { $0 + $1.bytes }
            let hint = "re-run with --yes to move these to Trash"

            if json {
                Output.line(try Output.json(
                    CleanPlanDTO(dry_run: true, planned: dtos, total_bytes: total, hint: hint)
                ))
            } else {
                Output.line("plan (dry run): move \(dtos.count) item(s) to Trash")
                Output.line(HumanTables.devItems(dtos, totalBytes: total))
                Output.line("hint: \(hint)")
            }
        }

        // MARK: - Trash (--yes)

        private func trash(_ planned: [DevSelection.Item]) throws {
            let fileManager = FileManager.default
            var trashed: [TrashedItemDTO] = []
            var failed: [FailedItemDTO] = []
            var reclaimed: Int64 = 0

            for item in planned {
                let category = item.category.rawValue
                let risk = item.category.riskToken
                // A path that vanished between scan and trash is success-with-note, not failure.
                if !fileManager.fileExists(atPath: item.path) {
                    trashed.append(TrashedItemDTO(
                        path: item.path, category: category, risk: risk,
                        bytes: item.bytes, note: "already gone"
                    ))
                    continue
                }
                do {
                    try fileManager.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
                    trashed.append(TrashedItemDTO(
                        path: item.path, category: category, risk: risk,
                        bytes: item.bytes, note: nil
                    ))
                    reclaimed += item.bytes
                } catch {
                    if !fileManager.fileExists(atPath: item.path) {
                        trashed.append(TrashedItemDTO(
                            path: item.path, category: category, risk: risk,
                            bytes: item.bytes, note: "already gone"
                        ))
                    } else {
                        failed.append(FailedItemDTO(
                            path: item.path, message: error.localizedDescription
                        ))
                    }
                }
            }

            let result = CleanResultDTO(
                dry_run: false, trashed: trashed, failed: failed, reclaimed_bytes: reclaimed
            )

            if json {
                Output.line(try Output.json(result))
            } else {
                let goneCount = trashed.filter { $0.note != nil }.count
                var summary = "trashed \(trashed.count) item(s), reclaimed \(ByteSize.human(reclaimed))"
                if goneCount > 0 { summary += " (\(goneCount) already gone)" }
                Output.line(summary)
                if !failed.isEmpty {
                    Output.line("failed \(failed.count) item(s):")
                    for failure in failed {
                        Output.line("  \(failure.path): \(failure.message)")
                    }
                }
            }

            // Some clean operations genuinely failed: report data on stdout, exit 5.
            if !failed.isEmpty {
                throw ExitCode(ExitCategory.partialFailure.rawValue)
            }
        }
    }
}
