import StackdustCore
import Foundation

/// Renders live scan progress to stderr, but only when stderr is a terminal.
///
/// The scanner already throttles its `.progress` updates (~50 ms), so this just formats each
/// snapshot onto a single carriage-return-rewound line and clears it when the scan finishes.
/// When stderr is not a TTY every method is a no-op, keeping piped/redirected output clean.
final class ProgressReporter {
    private let enabled: Bool
    private var lastLineWidth = 0

    init(enabled: Bool = Output.stderrIsTTY) {
        self.enabled = enabled
    }

    func report(_ progress: ScanProgress) {
        guard enabled else { return }
        let line = "Scanning… \(progress.itemsScanned) items, \(ByteSize.human(progress.bytesAccumulated))"
        // Pad to overwrite any longer previous line, then rewind the cursor.
        let padded = line.count < lastLineWidth
            ? line + String(repeating: " ", count: lastLineWidth - line.count)
            : line
        lastLineWidth = line.count
        Output.rawStderr("\r" + padded)
    }

    /// Clears the progress line so subsequent output starts on a clean row.
    func finish() {
        guard enabled, lastLineWidth > 0 else { return }
        Output.rawStderr("\r" + String(repeating: " ", count: lastLineWidth) + "\r")
        lastLineWidth = 0
    }
}
