import Foundation

/// Coarse grouping of developer-reclaimable items, used to colour/label them later.
/// Backed by `String` so it can be persisted or shown without a separate mapping table.
public enum DevCategory: String, Sendable {
    /// Xcode build products, device-support symbols, and Xcode's own caches.
    case xcodeBuild
    /// Xcode archives. Kept separate from `xcodeBuild` because they hold the dSYMs of
    /// released builds and cannot be regenerated, so they must never share a risk tier
    /// with regenerable build products.
    case xcodeArchives
    /// CoreSimulator device images and caches.
    case simulators
    /// Downloaded, re-fetchable package/dependency data (SwiftPM, npm, Gradle, Cargo, …).
    case packageCache
    /// Project-local, regenerable build output (`target`, `build`, `.build`, `__pycache__`, …).
    case projectArtifacts
    /// Docker's Linux VM disk images.
    case docker
}

/// How much you lose by trashing a dev item, from safest to riskiest. Used to warn the user
/// before deletion.
public enum DevRiskTier: String, Sendable {
    /// Recreated automatically at no cost beyond build time.
    case safe
    /// Comes back on demand, but the next build/install pays with network and time.
    case costsTime
    /// Trashing destroys state that is not automatically reproducible.
    case losesState
}

extension DevCategory {
    /// The risk of trashing an item of this category.
    public var riskTier: DevRiskTier {
        switch self {
        case .xcodeBuild:
            return .safe
        case .packageCache, .projectArtifacts:
            return .costsTime
        case .simulators, .xcodeArchives, .docker:
            return .losesState
        }
    }

    /// One plain-language sentence explaining what happens if an item of this category is trashed.
    public var consequence: String {
        switch self {
        case .xcodeBuild:
            return "Xcode recreates this as needed: build products return on the next build, device-support symbols re-download when a device connects. You lose only build time."
        case .packageCache:
            return "Package managers re-download these on demand. The next install or build needs network and extra time."
        case .projectArtifacts:
            return "The project's own tooling regenerates this (npm install, cargo build, …) the next time you build. Only worth deleting for projects you are not actively using."
        case .simulators:
            return "Xcode recreates simulator devices, but apps installed on them and their data are gone for good."
        case .xcodeArchives:
            return "Archives hold the debug symbols (dSYMs) of your released builds — without them crash reports from those builds cannot be symbolicated. They cannot be regenerated."
        case .docker:
            return "Docker's VM disk holds all local images, containers, and volumes. Re-pullable images come back; anything not pushed elsewhere is gone."
        }
    }
}

/// The set of rules that identify developer-reclaimable items in a scanned tree.
///
/// There are two rule kinds:
/// - **Absolute path rules** match a fixed location under the user's home directory
///   (e.g. `~/Library/Developer/Xcode/DerivedData`), plus one suffix rule for the
///   `… DeviceSupport` directories directly under `~/Library/Developer/Xcode`.
/// - **Name rules** match a directory of a given name anywhere in the tree, some behind a
///   guard that avoids false positives (e.g. `Pods` only next to a `Podfile`).
///
/// The home directory is injected so tests can point the absolute rules at a synthetic tree.
/// All matching reads only the in-memory `FileNode` tree; it never touches the disk.
public struct DevItemCatalog {

    /// A guard that must hold for a name rule to match.
    enum NameGuard {
        /// No guard: the name alone is sufficient.
        case none
        /// A sibling (another child of the same parent) with one of these names must exist.
        case sibling(Set<String>)
        /// A direct child with this name must exist.
        case child(String)
    }

    /// A name rule: the category to assign and the guard that must hold.
    struct NameRule {
        let category: DevCategory
        let guardKind: NameGuard
    }

    /// Absolute path (no trailing slash) → category, for the fixed home-relative locations.
    let exactPaths: [String: DevCategory]

    /// The directory whose direct children ending in " DeviceSupport" are Xcode device support.
    let deviceSupportParent: String

    /// Directory name → rule, matched anywhere in the tree.
    let nameRules: [String: NameRule]

    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        // Normalise: drop a trailing slash so joins produce "<home>/<relative>", not "//".
        let home = (home.count > 1 && home.hasSuffix("/")) ? String(home.dropLast()) : home

        // Home-relative location → category. Turned into absolute paths below.
        let relative: [(String, DevCategory)] = [
            ("Library/Developer/Xcode/DerivedData", .xcodeBuild),
            ("Library/Developer/Xcode/Archives", .xcodeArchives),
            ("Library/Developer/Xcode/UserData/Previews", .xcodeBuild),
            ("Library/Developer/CoreSimulator/Devices", .simulators),
            ("Library/Developer/CoreSimulator/Caches", .simulators),
            ("Library/Caches/com.apple.dt.Xcode", .xcodeBuild),
            ("Library/Caches/org.swift.swiftpm", .packageCache),
            ("Library/org.swift.swiftpm", .packageCache),
            ("Library/Caches/CocoaPods", .packageCache),
            ("Library/Caches/org.carthage.CarthageKit", .packageCache),
            ("Library/Caches/Homebrew", .packageCache),
            ("Library/Caches/pip", .packageCache),
            ("Library/Caches/Yarn", .packageCache),
            (".npm", .packageCache),
            (".gradle/caches", .packageCache),
            (".m2/repository", .packageCache),
            (".cargo/registry", .packageCache),
            (".cargo/git", .packageCache),
            ("go/pkg/mod", .packageCache),
            ("Library/Containers/com.docker.docker/Data/vms", .docker),
        ]
        var exact: [String: DevCategory] = [:]
        for (path, category) in relative {
            exact["\(home)/\(path)"] = category
        }
        self.exactPaths = exact
        self.deviceSupportParent = "\(home)/Library/Developer/Xcode"

        self.nameRules = [
            "node_modules": NameRule(category: .packageCache, guardKind: .none),
            "__pycache__": NameRule(category: .projectArtifacts, guardKind: .none),
            ".terraform": NameRule(category: .packageCache, guardKind: .none),
            "DerivedData": NameRule(category: .xcodeBuild, guardKind: .none),
            "Pods": NameRule(category: .packageCache, guardKind: .sibling(["Podfile"])),
            ".build": NameRule(category: .projectArtifacts, guardKind: .sibling(["Package.swift"])),
            "Carthage": NameRule(category: .packageCache, guardKind: .sibling(["Cartfile"])),
            "target": NameRule(category: .projectArtifacts, guardKind: .sibling(["Cargo.toml"])),
            "build": NameRule(category: .projectArtifacts,
                              guardKind: .sibling(["gradlew", "build.gradle", "build.gradle.kts"])),
            ".venv": NameRule(category: .projectArtifacts, guardKind: .child("pyvenv.cfg")),
            "venv": NameRule(category: .projectArtifacts, guardKind: .child("pyvenv.cfg")),
            ".next": NameRule(category: .projectArtifacts, guardKind: .sibling(["package.json"])),
            ".nuxt": NameRule(category: .projectArtifacts, guardKind: .sibling(["package.json"])),
        ]
    }

    /// Returns the category if `node` (whose absolute path is `path`) is a dev-item root, else nil.
    /// Only directories match; guards are checked against the in-memory tree, never the disk.
    func category(for node: FileNode, path: String) -> DevCategory? {
        guard node.isDirectory else { return nil }

        if let category = exactPaths[path] {
            return category
        }
        if node.name.hasSuffix(" DeviceSupport"),
           path == "\(deviceSupportParent)/\(node.name)" {
            return .xcodeBuild
        }
        if let rule = nameRules[node.name], satisfies(rule.guardKind, at: node) {
            return rule.category
        }
        return nil
    }

    private func satisfies(_ guardKind: NameGuard, at node: FileNode) -> Bool {
        switch guardKind {
        case .none:
            return true
        case .sibling(let names):
            guard let siblings = node.parent?.children else { return false }
            return siblings.contains { $0 !== node && names.contains($0.name) }
        case .child(let name):
            guard let children = node.children else { return false }
            return children.contains { $0.name == name }
        }
    }
}
