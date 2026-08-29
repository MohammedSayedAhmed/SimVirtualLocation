import CoreLocation
import XCTest
@testable import SimVLLogic

/// The GPX file IS the behaviour: `play` sleeps for the gaps between timestamps, so a
/// wrong file is a wrong drive. These parse what was actually written.
final class GPXRouteTests: XCTestCase {

    private let parser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func times(in url: URL) throws -> [Date] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var stamps: [Date] = []
        var rest = text[...]
        while let open = rest.range(of: "<time>"), let close = rest.range(of: "</time>") {
            let stamp = String(rest[open.upperBound..<close.lowerBound])
            guard let date = parser.date(from: stamp) else {
                XCTFail("unparseable timestamp \(stamp)")
                break
            }
            stamps.append(date)
            rest = rest[close.upperBound...]
        }
        return stamps
    }

    func testStationaryHoldRepeatsOnePointOnSchedule() throws {
        let point = CLLocationCoordinate2D(latitude: 25.5, longitude: 51.5)
        let url = try GPXRoute.writeStationary(coordinate: point, interval: 10, duration: 60)
        defer { try? FileManager.default.removeItem(at: url) }

        let stamps = try times(in: url)
        XCTAssertEqual(stamps.count, 6)
        for (previous, next) in zip(stamps, stamps.dropFirst()) {
            XCTAssertEqual(next.timeIntervalSince(previous), 10, accuracy: 0.001)
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "lat=\"25.5\"").count - 1, 6)
    }

    func testDriveSamplesKeepTheirFractionalSeconds() throws {
        // Whole-second truncation once collapsed runs of sub-second points onto one
        // timestamp, so the player injected bursts and slept a second — 1 Hz movement.
        let line = Geo.line(metres: 20, count: 3)
        let samples = [
            DriveProfile.Sample(coordinate: line[0], offset: 0),
            DriveProfile.Sample(coordinate: line[1], offset: 0.25),
            DriveProfile.Sample(coordinate: line[2], offset: 0.5),
        ]
        let url = try GPXRoute.write(samples: samples)
        defer { try? FileManager.default.removeItem(at: url) }

        let stamps = try times(in: url)
        XCTAssertEqual(stamps.count, 3)
        XCTAssertEqual(stamps[1].timeIntervalSince(stamps[0]), 0.25, accuracy: 0.001)
        XCTAssertEqual(stamps[2].timeIntervalSince(stamps[1]), 0.25, accuracy: 0.001)
    }

    func testConstantSpeedRouteTicksOncePerSecond() throws {
        let url = try GPXRoute.write(coordinates: Geo.line(metres: 500, count: 2), speed: 10)
        defer { try? FileManager.default.removeItem(at: url) }

        let stamps = try times(in: url)
        XCTAssertGreaterThan(stamps.count, 45)   // ~50 points at 10 m per second
        for (previous, next) in zip(stamps, stamps.dropFirst()) {
            XCTAssertEqual(next.timeIntervalSince(previous), 1, accuracy: 0.001)
        }
    }

    func testEmptyRoutesAreRefusedNotWritten() {
        XCTAssertThrowsError(try GPXRoute.write(coordinates: [], speed: 1))
        XCTAssertThrowsError(try GPXRoute.write(samples: []))
    }
}
