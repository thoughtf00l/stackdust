import XCTest
@testable import StackdustCLI

final class ByteSizeTests: XCTestCase {

    // MARK: - Parsing

    func testRawBytes() throws {
        XCTAssertEqual(try ByteSize.parse("0"), 0)
        XCTAssertEqual(try ByteSize.parse("1048576"), 1_048_576)
        XCTAssertEqual(try ByteSize.parse("  42 "), 42, "surrounding whitespace is trimmed")
    }

    func testDecimalSuffixes() throws {
        XCTAssertEqual(try ByteSize.parse("1K"), 1_000)
        XCTAssertEqual(try ByteSize.parse("500M"), 500_000_000)
        XCTAssertEqual(try ByteSize.parse("2G"), 2_000_000_000)
        XCTAssertEqual(try ByteSize.parse("1T"), 1_000_000_000_000)
    }

    func testSuffixIsCaseInsensitive() throws {
        XCTAssertEqual(try ByteSize.parse("500m"), 500_000_000)
        XCTAssertEqual(try ByteSize.parse("2g"), 2_000_000_000)
    }

    func testFractionalWithSuffix() throws {
        XCTAssertEqual(try ByteSize.parse("1.5G"), 1_500_000_000)
        XCTAssertEqual(try ByteSize.parse("0.5K"), 500)
    }

    func testGarbageThrows() {
        for bad in ["", "   ", "abc", "10X", "1.2.3", "M", "-5", "-5M", "1.5", "0x10", "100 MB"] {
            XCTAssertThrowsError(try ByteSize.parse(bad), "expected '\(bad)' to be rejected") { error in
                XCTAssertEqual(error as? ByteSize.ParseError, ByteSize.ParseError(input: bad))
            }
        }
    }

    // MARK: - Human formatting

    func testHumanFormatting() {
        XCTAssertEqual(ByteSize.human(0), "0 B")
        XCTAssertEqual(ByteSize.human(512), "512 B")
        XCTAssertEqual(ByteSize.human(1_000), "1.0 KB")
        XCTAssertEqual(ByteSize.human(1_500_000_000), "1.5 GB")
        XCTAssertEqual(ByteSize.human(125_829_120), "125.8 MB")
    }
}
