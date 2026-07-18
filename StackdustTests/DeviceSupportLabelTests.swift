import XCTest
@testable import Stackdust

final class DeviceSupportLabelTests: XCTestCase {

    func testModernFormatWithKnownModelId() {
        let label = AppleDeviceNames.deviceSupportLabel(
            childName: "iPhone14,2 15.0 (19A346)", platform: "iOS"
        )
        XCTAssertEqual(label, "iPhone 13 Pro — iOS 15.0")
    }

    func testModernFormatWithUnknownModelId() {
        // An id absent from the table falls back to the raw model identifier, not a wrong name.
        let label = AppleDeviceNames.deviceSupportLabel(
            childName: "iPhone99,9 26.0 (99Z999)", platform: "iOS"
        )
        XCTAssertEqual(label, "iPhone99,9 — iOS 26.0")
    }

    func testOldArchSuffixedFormatWithoutModelId() {
        // Old-style folder: no model id, just version, build, and architecture.
        let label = AppleDeviceNames.deviceSupportLabel(
            childName: "15.0 (19A346) arm64e", platform: "iOS"
        )
        XCTAssertEqual(label, "iOS 15.0")
    }

    func testGarbageFallsBackToRawName() {
        let label = AppleDeviceNames.deviceSupportLabel(
            childName: "not-a-device-folder", platform: "iOS"
        )
        XCTAssertEqual(label, "not-a-device-folder")
    }

    func testPlatformWordThreadedFromParentDirectory() {
        // The platform comes from the "<platform> DeviceSupport" parent, so a watchOS folder is
        // labelled with its own platform, not a hardcoded "iOS".
        let label = AppleDeviceNames.deviceSupportLabel(
            childName: "Watch6,1 10.0 (21R355)", platform: "watchOS"
        )
        XCTAssertEqual(label, "Apple Watch Series 6 — watchOS 10.0")
    }
}
