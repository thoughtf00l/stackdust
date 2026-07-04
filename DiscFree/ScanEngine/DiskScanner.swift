import Foundation

/// UI-independent disk scanner.
///
/// Enumerates a directory subtree with a bounded worker pool and reports progress through
/// an `AsyncThrowingStream`. The stream emits `.progress` updates (throttled to ~50 ms) and
/// finishes with a single `.finished` carrying the fully aggregated tree.
///
/// Cancellation is cooperative: cancelling the task that consumes the stream tears the
/// stream down, which cancels the scan; the stream then finishes with `CancellationError`.
final class DiskScanner: Sendable {

    /// Progress emission interval.
    private let progressInterval: DispatchTimeInterval = .milliseconds(50)

    init() {}

    func scan(at root: URL) -> AsyncThrowingStream<ScanUpdate, Error> {
        let workerCount = ProcessInfo.processInfo.activeProcessorCount
        let interval = progressInterval

        return AsyncThrowingStream { continuation in
            let coordinator: ScanCoordinator
            do {
                coordinator = try ScanCoordinator(root: root, workerCount: workerCount)
            } catch {
                continuation.finish(throwing: error)
                return
            }

            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    coordinator.cancel()
                }
            }

            let driver = DispatchQueue(label: "org.cosmoshark.DiscFree.scan", qos: .userInitiated)
            driver.async {
                let timer = DispatchSource.makeTimerSource(
                    queue: DispatchQueue.global(qos: .utility)
                )
                timer.schedule(deadline: .now() + interval, repeating: interval)
                timer.setEventHandler {
                    continuation.yield(.progress(coordinator.snapshotProgress()))
                }
                timer.activate()

                do {
                    let tree = try coordinator.run()
                    timer.cancel()
                    continuation.yield(.progress(coordinator.snapshotProgress()))
                    continuation.yield(.finished(tree))
                    continuation.finish()
                } catch {
                    timer.cancel()
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
