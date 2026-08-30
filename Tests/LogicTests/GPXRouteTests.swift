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

    func testWritingReplacesAndDeletesThePreviousFile() throws {
        // Nothing ever deleted these; a day of holds and legs left hundreds behind.
        let point = CLLocationCoordinate2D(latitude: 25.5, longitude: 51.5)
        let first = try GPXRoute.writeStationary(coordinate: point, interval: 10, duration: 60)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))

        let second = try GPXRoute.writeStationary(coordinate: point, interval: 10, duration: 60)
        defer { try? FileManager.default.removeItem(at: second) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path),
                       "the replaced file must be deleted, not left to accumulate")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testLeftoverSweepTakesOldRunsFilesAndNothingElse() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory

        // A file a previous run (or a crash) left behind, and two bystanders.
        let leftover = directory.appendingPathComponent("simvirtuallocation-oldrun-leftover.gpx")
        let wrongSuffix = directory.appendingPathComponent("simvirtuallocation-not-a-route.txt")
        let wrongPrefix = directory.appendingPathComponent("someoneelses-route.gpx")
        for url in [leftover, wrongSuffix, wrongPrefix] {
            try "x".write(to: url, atomically: true, encoding: .utf8)
        }
        defer {
            for url in [leftover, wrongSuffix, wrongPrefix] { try? manager.removeItem(at: url) }
        }

        // A file THIS run just wrote, which the sweep must not touch.
        let live = try GPXRoute.writeStationary(
            coordinate: CLLocationCoordinate2D(latitude: 25.5, longitude: 51.5),
            interval: 10, duration: 60)
        defer { try? manager.removeItem(at: live) }

        GPXRoute.removeLeftovers()

        XCTAssertFalse(manager.fileExists(atPath: leftover.path), "an old run's file goes")
        XCTAssertTrue(manager.fileExists(atPath: wrongSuffix.path), "non-GPX files are not ours to delete")
        XCTAssertTrue(manager.fileExists(atPath: wrongPrefix.path), "other apps' files are not ours to delete")
        XCTAssertTrue(manager.fileExists(atPath: live.path), "this run's own live file survives")
    }

    func testEmptyRoutesAreRefusedNotWritten() {
        XCTAssertThrowsError(try GPXRoute.write(coordinates: [], speed: 1))
        XCTAssertThrowsError(try GPXRoute.write(samples: []))
    }
}
