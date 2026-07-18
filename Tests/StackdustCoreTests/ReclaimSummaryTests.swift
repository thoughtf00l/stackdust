import XCTest
@testable import StackdustCore

final class ReclaimSummaryTests: XCTestCase {

    // MARK: - Synthetic tree helpers (mirror DevClassifierTests; no disk involved)

    private func file(_ name: String, _ size: Int64) -> FileNode {
        FileNode(name: name, isDirectory: false, allocatedSize: size, parent: nil)
    }

    private func dir(_ name: String, _ children: [FileNode]) -> FileNode {
        let node = FileNode(name: name, isDirectory: true, parent: nil)
        node.children = children
        for child in children { child.parent = node }
        node.allocatedSize = children.reduce(0) { $0 + $1.allocatedSize }
        return node
    }

    /// A fake home so the absolute-path rules point at a synthetic tree, not the real machine.
    private let home = "/fake/home"
    private var catalog: DevItemCatalog { DevItemCatalog(home: home) }

    // MARK: - Grouping, sorting, paths, node identity

    func testGroupsAndItemsSortedWithCorrectPathsAndIdentity() throws {
        // Two package-cache items (two node_modules), one projectArtifacts item (a Rust target
        // next to a Cargo.toml) and one xcodeBuild item, arranged so both the group order and the
        // intra-group item order are non-trivial.
        let bigNodeModules = dir("node_modules", [file("dep", 5_000)])   // packageCache 5_000
        let projA = dir("projA", [bigNodeModules, file("src.js", 10)])

        let target = dir("target", [file("app", 800)])                   // projectArtifacts 800
        let projB = dir("projB", [target, file("Cargo.toml", 10)])

        let smallNodeModules = dir("node_modules", [file("dep", 2_000)]) // packageCache 2_000
        let projC = dir("projC", [smallNodeModules])

        let derived = dir("DerivedData", [file("build.o", 9_000)])       // xcodeBuild 9_000
        let xcode = dir("Xcode", [derived])
        let library = dir("Library", [dir("Developer", [xcode])])

        let root = dir(home, [dir("code", [projA, projB, projC]), library])

        DevClassifier.classify(root, using: catalog)
        let groups = ReclaimSummary.build(from: root)

        // Group totals: packageCache 7_000, xcodeBuild 9_000, projectArtifacts 800.
        // Sorted by totalBytes descending → xcodeBuild, packageCache, projectArtifacts.
        XCTAssertEqual(groups.map(\.category), [.xcodeBuild, .packageCache, .projectArtifacts])
        XCTAssertEqual(groups.map(\.totalBytes), [9_000, 7_000, 800])

        // totalBytes equals the sum of its items' bytes for every group.
        for group in groups {
            XCTAssertEqual(group.totalBytes, group.items.reduce(0) { $0 + $1.bytes })
        }

        // packageCache items sorted by bytes descending, with correct absolute paths and node
        // identity pointing at the classified roots (not copies).
        let pkg = try XCTUnwrap(groups.first { $0.category == .packageCache })
        XCTAssertEqual(pkg.items.map(\.bytes), [5_000, 2_000])
        XCTAssertEqual(
            pkg.items.map(\.path),
            ["\(home)/code/projA/node_modules", "\(home)/code/projC/node_modules"]
        )
        XCTAssertTrue(pkg.items.first?.node === bigNodeModules)
        XCTAssertTrue(pkg.items.last?.node === smallNodeModules)

        // xcodeBuild item: correct path and identity, bytes captured from allocatedSize.
        let xcodeGroup = try XCTUnwrap(groups.first { $0.category == .xcodeBuild })
        XCTAssertEqual(xcodeGroup.items.count, 1)
        XCTAssertTrue(xcodeGroup.items.first?.node === derived)
        XCTAssertEqual(xcodeGroup.items.first?.path, "\(home)/Library/Developer/Xcode/DerivedData")
        XCTAssertEqual(xcodeGroup.items.first?.bytes, 9_000)
    }

    // MARK: - Empty results

    func testUnclassifiedTreeYieldsNoGroups() {
        // classify() never runs, so devCategory/devSize keep their defaults.
        let root = dir(home, [dir("code", [dir("node_modules", [file("dep", 5_000)])])])

        XCTAssertTrue(ReclaimSummary.build(from: root).isEmpty)
    }

    func testClassifiedTreeWithNoMatchesYieldsNoGroups() {
        let root = dir("/work", [dir("proj", [file("main.c", 100), file("README", 20)])])

        DevClassifier.classify(root, using: catalog)

        XCTAssertTrue(ReclaimSummary.build(from: root).isEmpty)
    }

    // MARK: - Non-descent: a dev root inside another matched root produces no second item

    func testNestedDevRootDoesNotProduceSecondItem() {
        let inner = dir("node_modules", [file("dep2", 200)])
        let nested = dir("some-pkg", [inner])
        let outer = dir("node_modules", [file("dep1", 1_000), nested])   // outermost match, 1_200
        let root = dir("/work", [outer])

        DevClassifier.classify(root, using: catalog)
        let groups = ReclaimSummary.build(from: root)

        XCTAssertEqual(groups.count, 1)
        let pkg = groups[0]
        XCTAssertEqual(pkg.category, .packageCache)
        XCTAssertEqual(pkg.items.count, 1, "the inner node_modules must not become a second item")
        XCTAssertTrue(pkg.items.first?.node === outer)
        XCTAssertEqual(pkg.items.first?.bytes, 1_200)
    }

    // MARK: - displayName copy

    /// The exhaustive switch in `displayName` already forces every case to be handled at compile
    /// time; this guards against an accidental empty string (same style as the consequence test).
    func testDisplayNameForEveryCategory() {
        let categories: [DevCategory] = [
            .xcodeBuild, .xcodeArchives, .simulators, .packageCache, .projectArtifacts, .docker,
        ]
        for category in categories {
            XCTAssertFalse(
                category.displayName.isEmpty,
                "\(category.rawValue) must have a non-empty displayName"
            )
        }
    }
}
