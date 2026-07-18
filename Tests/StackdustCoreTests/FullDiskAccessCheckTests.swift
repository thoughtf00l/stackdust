import XCTest
import Darwin
@testable import StackdustCore

final class FullDiskAccessCheckTests: XCTestCase {

    // MARK: - Pure decision (independent of the machine's real FDA state)

    func testEvaluateGrantedWhenProbeReadable() {
        XCTAssertEqual(
            FullDiskAccessCheck.evaluate(parentReadable: true, probeExists: true, probeReadable: true),
            .granted
        )
    }

    func testEvaluateDeniedWhenProbeExistsButUnreadable() {
        XCTAssertEqual(
            FullDiskAccessCheck.evaluate(parentReadable: true, probeExists: true, probeReadable: false),
            .denied
        )
    }

    func testEvaluateUndeterminedWhenProbeMissing() {
        XCTAssertEqual(
            FullDiskAccessCheck.evaluate(parentReadable: true, probeExists: false, probeReadable: false),
            .undetermined
        )
    }

    func testEvaluateUndeterminedWhenParentUnreadable() {
        // Parent unreadable means we cannot reason, regardless of the probe.
        XCTAssertEqual(
            FullDiskAccessCheck.evaluate(parentReadable: false, probeExists: true, probeReadable: false),
            .undetermined
        )
        XCTAssertEqual(
            FullDiskAccessCheck.evaluate(parentReadable: false, probeExists: true, probeReadable: true),
            .undetermined
        )
    }

    // MARK: - File-system primitives

    func testCanOpenReadableDirectory() {
        XCTAssertTrue(FullDiskAccessCheck.canOpenDirectory(NSTemporaryDirectory()))
    }

    func testCannotOpenMissingDirectory() {
        let missing = NSTemporaryDirectory() + "definitely-missing-\(UUID().uuidString)"
        XCTAssertFalse(FullDiskAccessCheck.exists(missing))
        XCTAssertFalse(FullDiskAccessCheck.canOpenDirectory(missing))
    }

    func testExistsForHomeLibrary() {
        XCTAssertTrue(FullDiskAccessCheck.exists("\(NSHomeDirectory())/Library"))
    }

    // MARK: - Real check reflects the current process

    func testStatusMatchesDirectProbeObservation() {
        let check = FullDiskAccessCheck()
        let status = check.status()

        // Reproduce the observation the type makes and confirm they agree, without hard-coding
        // whether this machine happens to have FDA.
        let parentReadable = FullDiskAccessCheck.canOpenDirectory("\(NSHomeDirectory())/Library")
        let firstExisting = check.probePaths.first { FullDiskAccessCheck.exists($0) }

        if !parentReadable {
            XCTAssertEqual(status, .undetermined)
        } else if let probe = firstExisting {
            let expected: FullDiskAccessStatus =
                FullDiskAccessCheck.canOpenDirectory(probe) ? .granted : .denied
            XCTAssertEqual(status, expected)
        } else {
            XCTAssertEqual(status, .undetermined)
        }
    }
}
