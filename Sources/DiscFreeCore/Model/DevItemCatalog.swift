import Foundation

/// Coarse grouping of reclaimable items, used to colour/label them later.
/// Backed by `String` so it can be persisted or shown without a separate mapping table.
/// `CaseIterable` so the CLI's `--category` list is derived from the enum, not a hand-kept
/// copy — this removes the "forgot to register a new category in the CLI" failure mode.
public enum DevCategory: String, Sendable, CaseIterable {
    /// Xcode build products, device-support symbols, and Xcode's own caches.
    case xcodeBuild
    /// Xcode archives. Kept separate from `xcodeBuild` because they hold the dSYMs of
    /// released builds and cannot be regenerated, so they must never share a risk tier
    /// with regenerable build products.
    case xcodeArchives
    /// Simulator/emulator device images and caches (CoreSimulator + Android AVDs).
    case simulators
    /// Downloaded, re-fetchable package/dependency data (SwiftPM, npm, Gradle, Cargo, …).
    case packageCache
    /// Project-local, regenerable build output (`target`, `build`, `.build`, `__pycache__`, …).
    case projectArtifacts
    /// Docker's Linux VM disk images.
    case docker
    /// Per-application caches under `~/Library/Caches`, one entry per app.
    case appCaches
    /// Diagnostic logs written by apps and macOS (`~/Library/Logs`).
    case logs
    /// Local iOS/iPadOS device backups (`~/Library/Application Support/MobileSync/Backup`).
    case iosBackups
    /// Adobe Premiere Pro / After Effects media caches.
    case adobeCache
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
        case .xcodeBuild, .logs:
            return .safe
        case .packageCache, .projectArtifacts, .appCaches, .adobeCache:
            return .costsTime
        case .simulators, .xcodeArchives, .docker, .iosBackups:
            return .losesState
        }
    }

    /// Short human-readable label for this category, for a category-first list.
    public var displayName: String {
        switch self {
        case .xcodeBuild:
            return "Xcode build products"
        case .xcodeArchives:
            return "Xcode archives"
        case .simulators:
            return "Simulators"
        case .packageCache:
            return "Package caches"
        case .projectArtifacts:
            return "Project build artifacts"
        case .docker:
            return "Docker VM disks"
        case .appCaches:
            return "Application caches"
        case .logs:
            return "Logs"
        case .iosBackups:
            return "iOS device backups"
        case .adobeCache:
            return "Adobe media caches"
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
            return "Simulator and emulator devices are recreated by their tools, but apps installed on them and their data are gone for good."
        case .xcodeArchives:
            return "Archives hold the debug symbols (dSYMs) of your released builds — without them crash reports from those builds cannot be symbolicated. They cannot be regenerated."
        case .docker:
            return "Docker's VM disk holds all local images, containers, and volumes. Re-pullable images come back; anything not pushed elsewhere is gone."
        case .appCaches:
            return "Apps rebuild their caches as you use them. Nothing is lost, but apps may start slower and re-download data."
        case .logs:
            return "Diagnostic logs written by apps and macOS. Deleting them loses only debugging history."
        case .iosBackups:
            return "Local backups of iPhones and iPads. A deleted backup cannot be recreated unless the device is available to back up again."
        case .adobeCache:
            return "Premiere Pro and After Effects rebuild their media caches when a project opens. Re-rendering takes time; nothing is lost."
        }
    }
}

/// The set of rules that identify reclaimable items in a scanned tree.
///
/// There are three rule kinds:
/// - **Absolute path rules** match a fixed location under the user's home directory
///   (e.g. `~/Library/Developer/Xcode/DerivedData`), plus one suffix rule for the
///   `… DeviceSupport` directories directly under `~/Library/Developer/Xcode`.
/// - **Children-of rules** match every *directory* that is a direct child of a listed
///   parent (the parent itself does not match), giving per-child granularity — e.g.
///   each app's folder under `~/Library/Caches` becomes its own `appCaches` item.
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

    /// Absolute parent path (no trailing slash) → category assigned to each of its direct child
    /// directories. `exactPaths` win over these (see `category(for:)`), so specific entries inside
    /// a listed parent keep their precise category while the rest fall to this blanket rule.
    let childrenOfParents: [String: DevCategory]

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
            (".android/avd", .simulators),
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
            (".gradle/wrapper", .packageCache),
            (".konan", .packageCache),
            ("Library/Android/sdk/system-images", .packageCache),
            (".m2/repository", .packageCache),
            (".cargo/registry", .packageCache),
            (".cargo/git", .packageCache),
            ("go/pkg/mod", .packageCache),
            ("Library/Containers/com.docker.docker/Data/vms", .docker),
            ("Library/Logs", .logs),
            ("Library/Application Support/MobileSync/Backup", .iosBackups),
            ("Library/Application Support/Adobe/Common/Media Cache Files", .adobeCache),
            ("Library/Application Support/Adobe/Common/Media Cache", .adobeCache),
        ]
        var exact: [String: DevCategory] = [:]
        for (path, category) in relative {
            exact["\(home)/\(path)"] = category
        }
        self.exactPaths = exact

        // Parent whose direct child directories inherit a category. `~/Library/Caches` gives
        // per-app granularity: every app's cache folder becomes its own `appCaches` item, except
        // the folders already pinned by `exactPaths` (Xcode, SwiftPM, CocoaPods, Homebrew, pip,
        // Yarn, …), which win over this blanket rule in `category(for:)`.
        self.childrenOfParents = [
            "\(home)/Library/Caches": .appCaches,
        ]

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
            ".gradle": NameRule(
                category: .projectArtifacts,
                guardKind: .sibling([
                    "gradlew", "build.gradle", "build.gradle.kts",
                    "settings.gradle", "settings.gradle.kts",
                ])),
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

        // Order matters. `exactPaths` is checked first so a specific location wins over the
        // blanket children-of rule below: e.g. `~/Library/Caches/com.apple.dt.Xcode` stays
        // `xcodeBuild` and `~/Library/Caches/Homebrew` (org.swift.swiftpm, CocoaPods, pip, Yarn,
        // …) stays `packageCache`, while every other child of `~/Library/Caches` falls through
        // to the `appCaches` blanket.
        if let category = exactPaths[path] {
            return category
        }
        if node.name.hasSuffix(" DeviceSupport"),
           path == "\(deviceSupportParent)/\(node.name)" {
            return .xcodeBuild
        }
        // Children-of rule: match when the candidate's parent path is a listed parent. The parent
        // is `path` with its last "/component" dropped; the parent itself never matches (its own
        // path is not among the values).
        if let slash = path.lastIndex(of: "/"),
           let category = childrenOfParents[String(path[..<slash])] {
            return category
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
