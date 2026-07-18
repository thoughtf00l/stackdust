import XCTest
@testable import StackdustCLI

final class OutputModelTests: XCTestCase {

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        try Output.makeJSONEncoder().encode(value)
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: encode(value))
        return try XCTUnwrap(object as? [String: Any])
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: encode(value))
    }

    // MARK: - Optional-field omission

    func testTreeNodeOmitsNilOptionals() throws {
        let file = TreeNodeDTO(
            name: "a", bytes: 10, dir: false, unreadable: nil, cloud_evicted: nil, children: nil
        )
        let keys = try jsonObject(file).keys
        XCTAssertEqual(Set(keys), ["name", "bytes", "dir"],
                       "nil children/unreadable/cloud_evicted are omitted")
    }

    func testTreeNodeIncludesPresentOptionals() throws {
        let dir = TreeNodeDTO(
            name: "d", bytes: 0, dir: true, unreadable: true, cloud_evicted: nil, children: []
        )
        let object = try jsonObject(dir)
        XCTAssertEqual(object["unreadable"] as? Bool, true)
        XCTAssertFalse(object.keys.contains("cloud_evicted"), "nil cloud_evicted is omitted")
        XCTAssertNotNil(object["children"])
    }

    func testTreeNodeIncludesCloudEvictedWhenSet() throws {
        let dir = TreeNodeDTO(
            name: "d", bytes: 0, dir: true, unreadable: nil, cloud_evicted: true, children: []
        )
        let object = try jsonObject(dir)
        XCTAssertEqual(object["cloud_evicted"] as? Bool, true)
        XCTAssertFalse(object.keys.contains("unreadable"), "nil unreadable is omitted")
    }

    func testTrashedItemOmitsNilNote() throws {
        let item = TrashedItemDTO(
            path: "/x", category: "packageCache", risk: "costs_time", bytes: 1, note: nil
        )
        XCTAssertFalse(try jsonObject(item).keys.contains("note"))

        let gone = TrashedItemDTO(
            path: "/x", category: "packageCache", risk: "costs_time", bytes: 1, note: "already gone"
        )
        XCTAssertEqual(try jsonObject(gone)["note"] as? String, "already gone")
    }

    // MARK: - Risk field

    func testDevItemIncludesRiskField() throws {
        let item = DevItemDTO(path: "/a", category: "docker", risk: "loses_state", bytes: 1)
        XCTAssertEqual(try jsonObject(item)["risk"] as? String, "loses_state")
    }

    func testTrashedItemIncludesRiskField() throws {
        let item = TrashedItemDTO(
            path: "/a", category: "xcodeBuild", risk: "safe", bytes: 1, note: nil
        )
        XCTAssertEqual(try jsonObject(item)["risk"] as? String, "safe")
    }

    func testCleanPlanItemsIncludeRisk() throws {
        let plan = CleanPlanDTO(
            dry_run: true,
            planned: [DevItemDTO(path: "/a", category: "docker", risk: "loses_state", bytes: 9)],
            total_bytes: 9,
            hint: "re-run with --yes to move these to Trash"
        )
        let planned = try XCTUnwrap(try jsonObject(plan)["planned"] as? [[String: Any]])
        XCTAssertEqual(planned.first?["risk"] as? String, "loses_state")
    }

    // MARK: - Round-trips (structure survives encode/decode)

    func testScanResultRoundTrips() throws {
        let tree = TreeNodeDTO(
            name: "/root", bytes: 30, dir: true, unreadable: nil, cloud_evicted: nil,
            children: [
                TreeNodeDTO(name: "big", bytes: 20, dir: false, unreadable: nil,
                            cloud_evicted: nil, children: nil),
                TreeNodeDTO(name: "sub", bytes: 10, dir: true, unreadable: nil,
                            cloud_evicted: true, children: []),
            ]
        )
        let result = ScanResultDTO(
            path: "/root", total_bytes: 30, unreadable_count: 0, cloud_evicted_count: 1,
            truncated: true, tree: tree
        )
        XCTAssertEqual(try roundTrip(result), result)
    }

    func testDevResultRoundTrips() throws {
        let result = DevResultDTO(
            items: [DevItemDTO(path: "/a", category: "packageCache", risk: "costs_time", bytes: 100)],
            total_bytes: 100
        )
        XCTAssertEqual(try roundTrip(result), result)
    }

    func testCleanPlanRoundTrips() throws {
        let plan = CleanPlanDTO(
            dry_run: true,
            planned: [DevItemDTO(path: "/a", category: "xcodeBuild", risk: "safe", bytes: 50)],
            total_bytes: 50,
            hint: "re-run with --yes to move these to Trash"
        )
        XCTAssertEqual(try roundTrip(plan), plan)
    }

    func testCleanResultRoundTrips() throws {
        let result = CleanResultDTO(
            dry_run: false,
            trashed: [TrashedItemDTO(
                path: "/a", category: "docker", risk: "loses_state", bytes: 9, note: "already gone"
            )],
            failed: [FailedItemDTO(path: "/b", message: "denied")],
            reclaimed_bytes: 0
        )
        XCTAssertEqual(try roundTrip(result), result)
    }

    // MARK: - Stable top-level schema shape

    func testScanResultTopLevelKeys() throws {
        let tree = TreeNodeDTO(
            name: "/r", bytes: 0, dir: true, unreadable: nil, cloud_evicted: nil, children: []
        )
        let result = ScanResultDTO(
            path: "/r", total_bytes: 0, unreadable_count: 0, cloud_evicted_count: 0,
            truncated: false, tree: tree
        )
        XCTAssertEqual(
            Set(try jsonObject(result).keys),
            ["path", "total_bytes", "unreadable_count", "cloud_evicted_count", "truncated", "tree"]
        )
    }

    func testCleanResultTopLevelKeys() throws {
        let result = CleanResultDTO(dry_run: false, trashed: [], failed: [], reclaimed_bytes: 0)
        XCTAssertEqual(
            Set(try jsonObject(result).keys),
            ["dry_run", "trashed", "failed", "reclaimed_bytes"]
        )
    }
}
