import Foundation

/// A user-facing failure carrying both a machine code (for `--json` consumers) and a
/// human-readable message, plus the process exit code it maps to.
///
/// Commands throw this from their work; the command wrapper renders it to stderr in the
/// requested format and exits with `exit`.
struct CLIError: Error {
    /// A stable, machine-parseable code: `path_not_found`, `not_a_directory`,
    /// `permission_denied`, `partial_failure`, `invalid_argument`, ...
    let code: String
    let message: String
    let path: String?
    let hint: String?
    let exit: ExitCategory

    init(
        code: String,
        message: String,
        path: String? = nil,
        hint: String? = nil,
        exit: ExitCategory
    ) {
        self.code = code
        self.message = message
        self.path = path
        self.hint = hint
        self.exit = exit
    }
}

extension CLIError {
    /// The JSON error object emitted on stderr under `--json`. Optional fields are omitted
    /// when nil (the synthesized encoder skips nil optionals).
    private struct Payload: Encodable {
        let error: String
        let message: String
        let path: String?
        let hint: String?
    }

    /// Renders the error to stderr in the requested format. Callers throw `ExitCode(exit.rawValue)`
    /// afterwards so ArgumentParser exits with the right code without printing anything itself.
    func emit(json: Bool) {
        if json {
            let payload = Payload(error: code, message: message, path: path, hint: hint)
            if let encoded = try? Output.json(payload) {
                Output.note(encoded)
            } else {
                Output.note(#"{"error":"\#(code)","message":"\#(message)"}"#)
            }
        } else {
            Output.note("error: \(message)")
            if let path { Output.note("  path: \(path)") }
            if let hint { Output.note("  hint: \(hint)") }
        }
    }
}
