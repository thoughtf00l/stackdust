import DiscFreeCore
import Foundation

/// Helpers around `DevCategory` for the CLI's `--category` flag.
///
/// `DevCategory` is not `CaseIterable` in DiscFreeCore, so the known set is enumerated here.
/// Keep this list in sync with the enum if categories are ever added there.
enum Categories {
    /// Every category the classifier can assign, in a stable order for help text and errors.
    static let all: [DevCategory] = [
        .xcodeBuild,
        .xcodeArchives,
        .simulators,
        .packageCache,
        .projectArtifacts,
        .docker,
    ]

    /// The valid `--category` values, comma-joined, for help text and error messages.
    static var validValuesList: String {
        all.map(\.rawValue).joined(separator: ", ")
    }

    /// Parses a comma-separated `--category` argument into a set of categories.
    ///
    /// An unknown token throws a `CLIError` with the `invalid_argument` code that lists the
    /// valid values, so the caller can render it and exit with a usage error.
    static func parse(_ raw: String) throws -> Set<DevCategory> {
        var result: Set<DevCategory> = []
        for token in raw.split(separator: ",") {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let category = DevCategory(rawValue: trimmed) else {
                throw CLIError(
                    code: "invalid_argument",
                    message: "Unknown category '\(trimmed)'. Valid values: \(validValuesList).",
                    exit: .usageError
                )
            }
            result.insert(category)
        }
        guard !result.isEmpty else {
            throw CLIError(
                code: "invalid_argument",
                message: "No valid category given. Valid values: \(validValuesList).",
                exit: .usageError
            )
        }
        return result
    }
}
