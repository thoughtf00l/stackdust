import Foundation

/// UI-independent disk scanner.
///
/// Enumerates a directory subtree with a bounded worker pool and reports progress through
/// an `AsyncThrowingStream`. The stream emits `.started(LiveScan)` first (exactly once, before
/// anything else) handing the consumer the handle that steers partial snapshots, then `.progress`
/// updates (throttled to ~50 ms), `.partial` detached tree snapshots (throttled, default ~500 ms,
/// each following the `LiveScan`'s current focus), and finishes with a single `.finished` carrying
/// the fully aggregated tree. No `.partial` is ever delivered after `.finished`.
///
/// Cancellation is cooperative: cancelling the task that consumes the stream tears the
/// stream down, which cancels the scan; the stream then finishes with `CancellationError`.
public final class DiskScanner: Sendable {

    /// Progress emission interval.
    private let progressInterval: DispatchTimeInterval = .milliseconds(50)

    /// Partial-snapshot shape (see `ScanCoordinator.partialSnapshot`).
    private static let partialMaxDepth = 5
    private static let partialTopChildren = 32
    private static let partialNodeBudget = 4000

    public init() {}

    /// Scans `root`, emitting throttled `.progress` and `.partial` updates and a terminal
    /// `.finished`. `partialInterval` controls how often a partial tree snapshot is emitted
    /// (injectable so tests can drive it fast).
    public func scan(
        at root: URL,
        partialInterval: DispatchTimeInterval = .milliseconds(500)
    ) -> AsyncThrowingStream<ScanUpdate, Error> {
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

            // Serializes yields and drops everything after the terminal event, so a partial-timer
            // firing that races the scan's completion can never be delivered after `.finished`.
            let emitter = Emitter(continuation)

            // Hand the consumer the focus handle before any other update; the partial timer reads
            // its focus path when building each snapshot so partials follow the user's navigation.
            let liveScan = LiveScan()
            emitter.yield(.started(liveScan))

            let driver = DispatchQueue(label: "org.cosmoshark.Stackdust.scan", qos: .userInitiated)
            driver.async {
                let timer = DispatchSource.makeTimerSource(
                    queue: DispatchQueue.global(qos: .utility)
                )
                timer.schedule(deadline: .now() + interval, repeating: interval)
                timer.setEventHandler {
                    emitter.yield(.progress(coordinator.snapshotProgress()))
                }
                timer.activate()

                let partialTimer = DispatchSource.makeTimerSource(
                    queue: DispatchQueue.global(qos: .utility)
                )
                // Fire the first partial quickly (≤ 150 ms) so the UI can leave its transitional
                // screen fast, then settle into the regular `partialInterval` cadence.
                let partialStart = DispatchTime.now()
                let firstPartial = min(
                    partialStart + .milliseconds(150), partialStart + partialInterval
                )
                partialTimer.schedule(deadline: firstPartial, repeating: partialInterval)
                partialTimer.setEventHandler {
                    emitter.yield(.partial(coordinator.partialSnapshot(
                        focusPath: liveScan.focusPath,
                        maxDepth: Self.partialMaxDepth,
                        topChildren: Self.partialTopChildren,
                        nodeBudget: Self.partialNodeBudget
                    )))
                }
                partialTimer.activate()

                do {
                    let tree = try coordinator.run()
                    timer.cancel()
                    partialTimer.cancel()
                    emitter.yield(.progress(coordinator.snapshotProgress()))
                    emitter.finish(with: tree)
                } catch {
                    timer.cancel()
                    partialTimer.cancel()
                    emitter.finish(throwing: error)
                }
            }
        }
    }
}

/// Guards the scan stream's terminal transition: yields are dropped once a terminal event has
/// been delivered, and the terminal event is delivered at most once. This makes the "no
/// `.partial` after `.finished`" contract hold despite `DispatchSourceTimer.cancel()` being
/// asynchronous (a handler already dispatched to the timer queue may still run after cancel).
private final class Emitter: @unchecked Sendable {
    private let lock = NSLock()
    private var isTerminated = false
    private let continuation: AsyncThrowingStream<ScanUpdate, Error>.Continuation

    init(_ continuation: AsyncThrowingStream<ScanUpdate, Error>.Continuation) {
        self.continuation = continuation
    }

    /// Yields a non-terminal update; ignored once the stream has terminated.
    func yield(_ update: ScanUpdate) {
        lock.lock()
        defer { lock.unlock() }
        guard !isTerminated else { return }
        continuation.yield(update)
    }

    /// Yields `.finished` and finishes the stream, at most once.
    func finish(with tree: FileNode) {
        lock.lock()
        defer { lock.unlock() }
        guard !isTerminated else { return }
        isTerminated = true
        continuation.yield(.finished(tree))
        continuation.finish()
    }

    /// Finishes the stream with an error, at most once.
    func finish(throwing error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !isTerminated else { return }
        isTerminated = true
        continuation.finish(throwing: error)
    }
}
