import XCTest
@testable import SimVLLogic

final class CoordinateParsingTests: XCTestCase {

    func testValidRangesIncludeTheWholeGlobe() {
        XCTAssertTrue(CoordinateParsing.isValid(latitude: 0, longitude: 0))
        XCTAssertTrue(CoordinateParsing.isValid(latitude: -90, longitude: -180))
        XCTAssertTrue(CoordinateParsing.isValid(latitude: 90, longitude: 180))
        XCTAssertTrue(CoordinateParsing.isValid(latitude: 25.16, longitude: 51.54))
    }

    func testOutOfRangeIsRejected() {
        XCTAssertFalse(CoordinateParsing.isValid(latitude: 90.01, longitude: 0))
        XCTAssertFalse(CoordinateParsing.isValid(latitude: -90.01, longitude: 0))
        XCTAssertFalse(CoordinateParsing.isValid(latitude: 0, longitude: 180.01))
        XCTAssertFalse(CoordinateParsing.isValid(latitude: 0, longitude: -180.01))
    }
}
