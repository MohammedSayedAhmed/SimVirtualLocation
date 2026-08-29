import CoreLocation
import XCTest
@testable import SimVLLogic

/// The drive profile is deliberately deterministic and physically constrained; every
/// property here maps to a bug the app actually shipped at some point.
final class DriveProfileTests: XCTestCase {

    private let urbanCruise: CLLocationSpeed = 14   // ~50 km/h: slow enough for lights

    func testSameSeedSameDriveTwice() {
        // The seed once came from Hasher, which is salted per launch — every restart
        // reshuffled every light. The whole point of the seed is that it does not.
        let path = Geo.line(metres: 5000, count: 2)
        let settings = DriveProfile.Settings(cruiseSpeed: urbanCruise, stops: true, seed: 42)

        let first = DriveProfile.build(path: path, settings: settings)
        let second = DriveProfile.build(path: path, settings: settings)

        XCTAssertEqual(first.count, second.count)
        for (a, b) in zip(first, second) {
            XCTAssertEqual(a.offset, b.offset)
            XCTAssertEqual(a.coordinate.latitude, b.coordinate.latitude)
        }
    }

    func testDifferentSeedDifferentDrive() {
        let path = Geo.line(metres: 5000, count: 2)
        let one = DriveProfile.build(path: path, settings: .init(cruiseSpeed: urbanCruise, stops: true, seed: 1))
        let two = DriveProfile.build(path: path, settings: .init(cruiseSpeed: urbanCruise, stops: true, seed: 2))
        XCTAssertNotEqual(one.map(\.offset), two.map(\.offset))
    }

    func testTimeOnlyMovesForward() {
        // Standstills once divided by a zero mean speed; a NaN or a backwards
        // timestamp here becomes a GPX the player cannot walk.
        let samples = DriveProfile.build(
            path: Geo.line(metres: 3000, count: 2),
            settings: .init(cruiseSpeed: urbanCruise, stops: true, seed: 7)
        )

        XCTAssertEqual(samples.first?.offset, 0)
        for (previous, next) in zip(samples, samples.dropFirst()) {
            XCTAssertTrue(next.offset.isFinite)
            XCTAssertGreaterThanOrEqual(next.offset, previous.offset)
        }
    }

    func testDriveCoversTheWholePath() {
        let path = Geo.line(metres: 3000, count: 2)
        let samples = DriveProfile.build(
            path: path,
            settings: .init(cruiseSpeed: urbanCruise, stops: false, seed: 3)
        )
        XCTAssertLessThanOrEqual(Geo.distance(samples.first!.coordinate, path.first!), 2)
        XCTAssertLessThanOrEqual(Geo.distance(samples.last!.coordinate, path.last!), 2)
    }

    func testPhysicsIsSlowerThanTeleportation() {
        // Even with no stops, accelerating from rest and braking to a halt must take
        // longer than the constant-speed ideal — that difference IS the realism.
        let path = Geo.line(metres: 3000, count: 2)
        let samples = DriveProfile.build(
            path: path,
            settings: .init(cruiseSpeed: urbanCruise, stops: false, seed: 3)
        )
        let ideal = 3000 / urbanCruise
        XCTAssertGreaterThan(samples.last!.offset, ideal)
    }

    func testTargetDurationIsHonouredWhenFeasible() {
        // Fitting to the routing estimate is how traffic gets in; a fit that quietly
        // lands somewhere else made the summary a lie.
        let path = Geo.line(metres: 3000, count: 2)
        let settings = DriveProfile.Settings(cruiseSpeed: urbanCruise, stops: true, seed: 9)

        let natural = DriveProfile.build(path: path, settings: settings).last!.offset
        let target = natural * 1.5
        let fitted = DriveProfile.build(path: path, settings: settings, targetDuration: target)

        XCTAssertEqual(fitted.last!.offset, target, accuracy: target * 0.02)
    }

    func testImpossibleTargetSquashesWithoutBreaking() {
        // A day-plan leg whose timetable cannot absorb a red light used to arrive
        // late and teleport. The profile now drops stops and clamps rather than
        // either blowing up or overshooting without bound.
        let path = Geo.line(metres: 3000, count: 2)
        let settings = DriveProfile.Settings(cruiseSpeed: urbanCruise, stops: true, seed: 5)

        let natural = DriveProfile.build(path: path, settings: settings).last!.offset
        let fitted = DriveProfile.build(path: path, settings: settings, targetDuration: natural * 0.1)

        XCTAssertLessThan(fitted.last!.offset, natural)
        XCTAssertTrue(fitted.last!.offset.isFinite)
        XCTAssertGreaterThan(fitted.last!.offset, 0)
    }
}
