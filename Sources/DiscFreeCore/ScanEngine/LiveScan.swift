import Synchronization

/// A handle that lets the UI steer the live partial snapshots emitted during a scan.
///
/// While a scan runs, the browsing UI lets the user drill into directories. The UI writes the
/// current focus path here as the user navigates; the partial-snapshot emitter reads it when
/// building each snapshot, so the detached copy follows the user's focus instead of staying
/// anchored at the scan root.
///
/// The path convention matches `TreePath.components(of:)`: the names from (but excluding) the
/// scan root down to the focus node. An empty path means the focus is the root itself.
public final class LiveScan: Sendable {
    private let focus = Mutex<[String]>([])

    /// Creates a handle focused on the scan root (an empty focus path).
    public init() {}

    /// The current focus path: names from below the scan root down to the focus node.
    /// The UI sets this as the user navigates; the emitter reads it when building each snapshot.
    public var focusPath: [String] {
        get { focus.withLock { $0 } }
        set { focus.withLock { $0 = newValue } }
    }
}
