import ArgumentParser
import Foundation

/// Root command for `stackdust`, an agent-friendly CLI over the Stackdust scan engine.
///
/// Design: primary data goes to stdout (`--json` on every data command), progress and errors
/// go to stderr, and the tool never prompts. It is meant to be driven by scripts and agents.
///
/// The availability annotation is required by ArgumentParser: its asynchronous `main()` is
/// gated to macOS 10.15+, so the root command type must match it or the synchronous overload
/// is selected and refuses to run an async command.
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
public struct Stackdust: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "stackdust",
        abstract: "Scan disk usage and reclaim developer caches on macOS.",
        discussion: """
        stackdust writes primary data to stdout and diagnostics to stderr. Pass --json to any \
        subcommand for machine-readable output. It never prompts; destructive actions require \
        an explicit --yes and only ever move items to the Trash.

        Exit codes:
          0  success (partial data, e.g. some unreadable directories, still counts)
          2  usage error (bad flag value, unknown category, or a non-directory path)
          3  path not found
          4  permission denied (a scan root may need the terminal app to have Full Disk Access:
             System Settings → Privacy & Security → Full Disk Access)
          5  partial failure (some clean operations failed)
        """,
        subcommands: [Scan.self, Dev.self, Clean.self]
    )

    public init() {}
}

/// Runs a subcommand's work, converting a thrown `CLIError` into a rendered message plus the
/// matching process exit code. Unexpected errors propagate to ArgumentParser's default handler.
func runCommand(json: Bool, _ body: () async throws -> Void) async throws {
    do {
        try await body()
    } catch let error as CLIError {
        error.emit(json: json)
        throw ExitCode(error.exit.rawValue)
    }
}
