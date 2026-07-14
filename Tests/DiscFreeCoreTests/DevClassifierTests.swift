import XCTest
@testable import DiscFreeCore

final class DevClassifierTests: XCTestCase {

    // MARK: - Synthetic tree helpers (mirror TreeEditorTests; no disk involved)

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

    // MARK: - Absolute path rules

    func testAbsolutePathRuleMatchesUnderInjectedHome() {
        let derived = dir("DerivedData", [file("build.o", 1_000)])
        let xcode = dir("Xcode", [derived])
        let root = dir(home, [dir("Library", [dir("Developer", [xcode])])])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(derived.devCategory, .xcodeBuild)
        XCTAssertEqual(derived.devSize, 1_000)
        XCTAssertEqual(root.devSize, 1_000, "aggregated up through non-matching ancestors")
        // The whole subtree is dev by definition, so its descendants are not descended into.
        XCTAssertNil(derived.children!.first!.devCategory)
        XCTAssertEqual(derived.children!.first!.devSize, 0)
    }

    func testMultiComponentAbsoluteRuleMatchesOnlyTheLeaf() {
        // `.gradle/caches` is a rule; the parent `.gradle` is not.
        let caches = dir("caches", [file("lib.jar", 4_000)])
        let gradle = dir(".gradle", [caches, file("gradle.properties", 10)])
        let root = dir(home, [gradle])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(caches.devCategory, .packageCache)
        XCTAssertNil(gradle.devCategory, "only .gradle/caches is a rule, not .gradle itself")
        XCTAssertEqual(gradle.devSize, 4_000)
    }

    func testArchivesClassifiedAsXcodeArchives() {
        // Archives are their own category, split out of xcodeBuild: they are not regenerable.
        let archives = dir("Archives", [file("MyApp.xcarchive", 2_000)])
        let xcode = dir("Xcode", [archives])
        let root = dir(home, [dir("Library", [dir("Developer", [xcode])])])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(archives.devCategory, .xcodeArchives)
        XCTAssertEqual(archives.devSize, 2_000)
    }

    // MARK: - " DeviceSupport" suffix rule

    func testDeviceSupportSuffixRule() {
        let ios = dir("iOS 17.0 DeviceSupport", [file("Symbols", 500)])
        let watch = dir("watchOS DeviceSupport", [file("Symbols", 300)])
        let bare = dir("DeviceSupport", [file("x", 200)])          // lacks the leading " "
        let other = dir("SomethingElse", [file("y", 100)])
        let xcode = dir("Xcode", [ios, watch, bare, other])
        let root = dir(home, [dir("Library", [dir("Developer", [xcode])])])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(ios.devCategory, .xcodeBuild)
        XCTAssertEqual(watch.devCategory, .xcodeBuild)
        XCTAssertNil(bare.devCategory, "'DeviceSupport' without the ' DeviceSupport' suffix must not match")
        XCTAssertNil(other.devCategory)
    }

    func testDeviceSupportSuffixOnlyMatchesDirectlyUnderXcode() {
        // A "… DeviceSupport" directory anywhere else must not match the suffix rule.
        let stray = dir("iOS DeviceSupport", [file("z", 111)])
        let root = dir(home, [stray])

        DevClassifier.classify(root, using: catalog)

        XCTAssertNil(stray.devCategory)
    }

    // MARK: - Name rules with and without their guard

    func testTargetMatchesOnlyNextToCargoToml() {
        let withGuard = dir("target", [file("app", 9_000)])
        let cargoProject = dir("rustproj", [withGuard, file("Cargo.toml", 100)])

        let withoutGuard = dir("target", [file("app", 7_000)])
        let plainProject = dir("otherproj", [withoutGuard, file("main.c", 50)])

        let root = dir("/work", [cargoProject, plainProject])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(withGuard.devCategory, .projectArtifacts)
        XCTAssertEqual(withGuard.devSize, 9_000)
        XCTAssertNil(withoutGuard.devCategory, "'target' without a sibling Cargo.toml must not match")
        XCTAssertEqual(withoutGuard.devSize, 0)
    }

    func testVenvMatchesOnlyWithPyvenvChild() {
        let withGuard = dir("venv", [file("pyvenv.cfg", 10), file("packages", 5_000)])
        let withoutGuard = dir(".venv", [file("packages", 3_000)])
        let root = dir("/work", [dir("a", [withGuard]), dir("b", [withoutGuard])])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(withGuard.devCategory, .projectArtifacts)
        XCTAssertEqual(withGuard.devSize, 5_010)
        XCTAssertNil(withoutGuard.devCategory, "a venv without a pyvenv.cfg child must not match")
    }

    func testBuildMatchesNextToAnyGradleMarker() {
        let buildDir = dir("build", [file("classes", 6_000)])
        let project = dir("gradleproj", [buildDir, file("build.gradle.kts", 40)])
        let root = dir("/work", [project])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(buildDir.devCategory, .projectArtifacts)
    }

    func testUnguardedNameRuleMatchesAnywhere() {
        let pycache = dir("__pycache__", [file("mod.pyc", 800)])
        let root = dir("/work", [dir("deep", [dir("pkg", [pycache])])])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(pycache.devCategory, .projectArtifacts)
        XCTAssertEqual(root.devSize, 800)
    }

    // MARK: - Outermost match wins

    func testOutermostNodeModulesWins() {
        let inner = dir("node_modules", [file("dep2", 200)])
        let nested = dir("some-pkg", [inner])
        let outer = dir("node_modules", [file("dep1", 1_000), nested])  // 1_200
        let root = dir("/work", [outer])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(outer.devCategory, .packageCache)
        XCTAssertEqual(outer.devSize, 1_200)
        XCTAssertNil(inner.devCategory, "the inner node_modules is inside the outer match")
        XCTAssertEqual(inner.devSize, 0, "descendants of a match root are not descended into")
    }

    // MARK: - devSize aggregation up through non-matching ancestors

    func testDevSizeAggregatesThroughNonMatchingAncestors() {
        let nmA = dir("node_modules", [file("d", 800)])
        let projA = dir("projA", [nmA, file("src.js", 50)])   // dev 800, alloc 850
        let nmB = dir("node_modules", [file("e", 300)])
        let projB = dir("projB", [nmB])                        // dev 300, alloc 300
        let workspace = dir("workspace", [projA, projB])       // dev 1_100
        let root = dir("/work", [workspace, file("README", 20)])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(projA.devSize, 800)
        XCTAssertEqual(projB.devSize, 300)
        XCTAssertEqual(workspace.devSize, 1_100)
        XCTAssertEqual(root.devSize, 1_100, "the top-level file contributes no dev bytes")
        XCTAssertNil(projA.devCategory)
        XCTAssertNil(workspace.devCategory)
    }

    // MARK: - TreeEditor keeps devSize consistent on removal

    func testRemoveSubtractsDevSizeFromAncestors() throws {
        let nm = dir("node_modules", [file("d", 800)])
        let projA = dir("projA", [nm, file("src.js", 50)])  // dev 800, alloc 850
        let root = dir("/work", [projA])

        DevClassifier.classify(root, using: catalog)
        XCTAssertEqual(root.devSize, 800)

        try TreeEditor.remove(nm, keeping: root)

        XCTAssertEqual(projA.devSize, 0)
        XCTAssertEqual(root.devSize, 0)
        // allocatedSize stays consistent too (only the plain file remains).
        XCTAssertEqual(projA.allocatedSize, 50)
        XCTAssertEqual(root.allocatedSize, 50)
    }

    // MARK: - "inside a dev item" parent-chain helper

    func testIsWithinDevItem() {
        let deep = file("mod.pyc", 100)
        let sub = dir("sub", [deep])
        let nm = dir("node_modules", [sub])           // dev root
        let proj = dir("proj", [nm, file("src.js", 10)])
        let root = dir("/work", [proj])

        DevClassifier.classify(root, using: catalog)

        XCTAssertTrue(DevClassifier.isWithinDevItem(nm), "the dev-item root itself counts")
        XCTAssertTrue(DevClassifier.isWithinDevItem(sub), "a descendant of a dev root")
        XCTAssertTrue(DevClassifier.isWithinDevItem(deep))
        XCTAssertFalse(DevClassifier.isWithinDevItem(proj), "proj holds a dev item but is not one")
        XCTAssertFalse(DevClassifier.isWithinDevItem(root))
    }

    // MARK: - Risk tier / consequence copy

    /// The exhaustive switches in `riskTier`/`consequence` already force every case to be
    /// handled at compile time; this guards the mapping and against an accidental empty string.
    func testRiskTierAndConsequenceForEveryCategory() {
        let expectedTier: [DevCategory: DevRiskTier] = [
            .xcodeBuild: .safe,
            .packageCache: .costsTime,
            .projectArtifacts: .costsTime,
            .simulators: .losesState,
            .xcodeArchives: .losesState,
            .docker: .losesState,
        ]
        for (category, tier) in expectedTier {
            XCTAssertEqual(category.riskTier, tier, "unexpected tier for \(category.rawValue)")
            XCTAssertFalse(
                category.consequence.isEmpty,
                "\(category.rawValue) must have a non-empty consequence"
            )
        }
    }
}
