import Foundation

/// Centralises where bytes go: primary data to stdout, everything else (progress, notes,
/// errors) to stderr, and JSON encoded with a stable, agent-friendly shape.
enum Output {
    /// True when stdout is attached to a terminal; used to decide whether decoration is wanted.
    static var stdoutIsTTY: Bool { isatty(STDOUT_FILENO) != 0 }
    /// True when stderr is attached to a terminal; gates live progress rendering.
    static var stderrIsTTY: Bool { isatty(STDERR_FILENO) != 0 }

    /// Writes primary data (a subcommand's result) to stdout with a trailing newline.
    static func line(_ text: String) {
        print(text)
    }

    /// Writes a diagnostic line (a note or hint) to stderr with a trailing newline.
    static func note(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// Writes raw bytes to stderr without a trailing newline (used by the progress line).
    static func rawStderr(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    /// A JSON encoder configured for deterministic, path-friendly output: keys are sorted so
    /// diffs and tests are stable, and slashes are left unescaped so paths stay readable.
    static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Encodes `value` to a single-line JSON string.
    static func json<T: Encodable>(_ value: T) throws -> String {
        let data = try makeJSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

/// The hint attached to every permission failure on a scan root: on macOS a directory can be
/// seen but not read until the *terminal* app (not `stackdust` itself) is granted Full Disk Access.
let fullDiskAccessHint =
    "Grant the terminal app Full Disk Access: System Settings → Privacy & Security → Full Disk Access."
