import Foundation
import AppKit

public enum FullDiskAccessStatus: Equatable {
    /// A protected location could be opened — the app has Full Disk Access.
    case granted
    /// A protected location exists but could not be opened — FDA is missing.
    case denied
    /// Could not determine (no probe present, or ~/Library itself unreadable).
    case undetermined
}

/// Detects Full Disk Access without private APIs by probing TCC-protected locations that
/// exist on a normal account (e.g. ~/Library/Safari, ~/Library/Application Support/com.apple.TCC).
/// Such a directory can be seen with `lstat` but fails to `open` with EPERM unless the app has
/// FDA, while the enclosing ~/Library stays readable.
public struct FullDiskAccessCheck {
    public static let defaultProbePaths: [String] = {
        let library = "\(NSHomeDirectory())/Library"
        return [
            "\(library)/Safari",
            "\(library)/Application Support/com.apple.TCC",
            "\(library)/Mail",
            "\(library)/Messages",
        ]
    }()

    let libraryPath: String
    let probePaths: [String]

    public init(
        libraryPath: String = "\(NSHomeDirectory())/Library",
        probePaths: [String] = FullDiskAccessCheck.defaultProbePaths
    ) {
        self.libraryPath = libraryPath
        self.probePaths = probePaths
    }

    /// Real check against the file system.
    public func status() -> FullDiskAccessStatus {
        let parentReadable = Self.canOpenDirectory(libraryPath)
        for path in probePaths where Self.exists(path) {
            return Self.evaluate(
                parentReadable: parentReadable,
                probeExists: true,
                probeReadable: Self.canOpenDirectory(path)
            )
        }
        return Self.evaluate(parentReadable: parentReadable, probeExists: false, probeReadable: false)
    }

    /// Pure decision, unit-tested independently of the machine's real FDA state.
    static func evaluate(
        parentReadable: Bool, probeExists: Bool, probeReadable: Bool
    ) -> FullDiskAccessStatus {
        guard parentReadable else { return .undetermined }
        guard probeExists else { return .undetermined }
        return probeReadable ? .granted : .denied
    }

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// A TCC-blocked directory fails `open` with EPERM even though it exists.
    static func canOpenDirectory(_ path: String) -> Bool {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    // MARK: - System Settings deep link

    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

    @MainActor
    public static func openSystemSettings() {
        NSWorkspace.shared.open(settingsURL)
    }
}
