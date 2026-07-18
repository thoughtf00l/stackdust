import ArgumentParser
import StackdustCLI

/// Thin executable entry point. All command logic lives in `StackdustCLI`.
///
/// This dispatches to the parsed command's async `run()` explicitly rather than calling
/// `Stackdust.main()`: in a top-level `main.swift` the compiler resolves `main()` to the
/// synchronous `ParsableCommand` overload, which then refuses to run an `AsyncParsableCommand`.
/// Parsing here and awaiting `run()` avoids that overload ambiguity entirely.
@main
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
enum StackdustMain {
    static func main() async {
        do {
            var command = try Stackdust.parseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            Stackdust.exit(withError: error)
        }
    }
}
