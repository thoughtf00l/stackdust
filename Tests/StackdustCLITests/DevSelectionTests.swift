import XCTest
@testable import StackdustCLI
@testable import StackdustCore

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

    // MARK: - Risk token (snake_case, one category per tier)

    func testRiskTokenPerTierInJSON() throws {
        // One category per DevRiskTier; the DTO's `risk` is built exactly as the commands do.
        let cases: [(DevCategory, String)] = [
            (.xcodeBuild, "safe"),          // .safe
            (.packageCache, "costs_time"),  // .costsTime
            (.docker, "loses_state"),       // .losesState
        ]
        for (category, expected) in cases {
            let dto = DevItemDTO(
                path: "/x", category: category.rawValue, risk: category.riskToken, bytes: 1
            )
            let data = try Output.makeJSONEncoder().encode(dto)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["risk"] as? String, expected, "risk for \(category.rawValue)")
        }
    }

    // MARK: - Human grouping

    func testDevItemsByCategoryGroupsWithHeadersAndRisk() {
        let items = DevSelection.collect(classifiedTree())
        let lines = HumanTables.devItemsByCategory(items)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Categories ordered by total size descending; each header carries displayName, total,
        // and the risk token in brackets; items are indented beneath, size descending.
        XCTAssertEqual(lines, [
            "Project build artifacts — 3.0 KB [costs_time]",
            "  3.0 KB  /fake/home/rustproj/target",
            "Package caches — 1.0 KB [costs_time]",
            "  1.0 KB  /fake/home/proj/node_modules",
            "Xcode build products — 500 B [safe]",
            "   500 B  /fake/home/ios/DerivedData",
            "total: 4.5 KB across 3 item(s)",
        ])
    }

    func testDevItemsByCategoryEmpty() {
        XCTAssertEqual(
            HumanTables.devItemsByCategory([]),
            "No developer-reclaimable items found."
        )
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
