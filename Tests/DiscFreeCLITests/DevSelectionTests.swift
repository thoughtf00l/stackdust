import XCTest
@testable import DiscFreeCLI
@testable import DiscFreeCore

final class DevSelectionTests: XCTestCase {
    private let file = TreeFixtures.file
    private let dir = TreeFixtures.dir

    private let home = "/fake/home"
    private var catalog: DevItemCatalog { DevItemCatalog(home: home) }

    /// Builds a classified tree with three dev roots of known sizes.
    private func classifiedTree() -> FileNode {
        let nodeModules = dir("node_modules", [file("dep", 1_000)])          // packageCache, 1000
        let proj = dir("proj", [nodeModules, file("src.js", 50)])

        let target = dir("target", [file("bin", 3_000)])                    // projectArtifacts, 3000
        let rustProj = dir("rustproj", [target, file("Cargo.toml", 10)])

        let derivedData = dir("DerivedData", [file("build.o", 500)])        // xcodeBuild, 500
        let ios = dir("ios", [derivedData])

        let root = dir(home, [proj, rustProj, ios])
        DevClassifier.classify(root, using: catalog)
        return root
    }

    func testCollectReturnsRootsSortedDescending() {
        let items = DevSelection.collect(classifiedTree())
        XCTAssertEqual(items.map(\.category), [.projectArtifacts, .packageCache, .xcodeBuild])
        XCTAssertEqual(items.map(\.bytes), [3_000, 1_000, 500])
        XCTAssertEqual(
            items.map(\.path),
            ["/fake/home/rustproj/target", "/fake/home/proj/node_modules", "/fake/home/ios/DerivedData"]
        )
    }

    func testCollectDoesNotDescendIntoMatchedItems() {
        let items = DevSelection.collect(classifiedTree())
        // Three roots only; the file inside node_modules must not appear as its own item.
        XCTAssertEqual(items.count, 3)
    }

    func testFilterByCategory() {
        let items = DevSelection.collect(classifiedTree())
        let filtered = DevSelection.filter(items, categories: [.packageCache], minSize: 0)
        XCTAssertEqual(filtered.map(\.category), [.packageCache])
        XCTAssertEqual(filtered.map(\.bytes), [1_000])
    }

    func testFilterByMinSize() {
        let items = DevSelection.collect(classifiedTree())
        let filtered = DevSelection.filter(items, categories: nil, minSize: 800)
        XCTAssertEqual(filtered.map(\.bytes), [3_000, 1_000], "the 500-byte item is below the threshold")
    }

    func testFilterByCategoryAndMinSizeTogether() {
        let items = DevSelection.collect(classifiedTree())
        let filtered = DevSelection.filter(
            items, categories: [.projectArtifacts, .xcodeBuild], minSize: 600
        )
        XCTAssertEqual(filtered.map(\.path), ["/fake/home/rustproj/target"])
    }

    func testNilCategoryMeansAllCategories() {
        let items = DevSelection.collect(classifiedTree())
        let filtered = DevSelection.filter(items, categories: nil, minSize: 0)
        XCTAssertEqual(filtered.count, 3)
    }

    // MARK: - Category flag parsing

    func testCategoryParseAcceptsKnownValues() throws {
        let parsed = try Categories.parse("packageCache, xcodeBuild")
        XCTAssertEqual(parsed, [.packageCache, .xcodeBuild])
    }

    func testCategoryParseAcceptsXcodeArchives() throws {
        XCTAssertEqual(try Categories.parse("xcodeArchives"), [.xcodeArchives])
    }

    func testValidValuesListIncludesXcodeArchives() {
        XCTAssertTrue(
            Categories.validValuesList.contains("xcodeArchives"),
            "xcodeArchives must appear in help/error text"
        )
    }

    func testCategoryParseRejectsUnknownValue() {
        XCTAssertThrowsError(try Categories.parse("packageCache,bogus")) { error in
            let cliError = error as? CLIError
            XCTAssertEqual(cliError?.code, "invalid_argument")
            XCTAssertEqual(cliError?.exit, .usageError)
        }
    }

    func testCategoryParseRejectsEmpty() {
        XCTAssertThrowsError(try Categories.parse("  ,  ")) { error in
            XCTAssertEqual((error as? CLIError)?.code, "invalid_argument")
        }
    }
}
