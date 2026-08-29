import CoreLocation
import XCTest
@testable import SimVLLogic

/// The day plan's whole promise is that arithmetic against the wall clock is right:
/// arrivals from distance and speed, overruns pushing later departures, and the
/// position at any instant being derivable after a restart.
final class DayPlanTests: XCTestCase {

    private func stop(_ name: String, departure: Int?, speed: Double = 60) -> DayPlanStop {
        DayPlanStop(
            name: name,
            latitude: Geo.baseLatitude,
            longitude: Geo.baseLongitude,
            departureMinutes: departure,
            speedKph: speed
        )
    }

    private func schedule(distances: [CLLocationDistance], stops: [DayPlanStop]) -> DaySchedule {
        DaySchedule.build(
            plan: DayPlan(stops: stops),
            on: Clock.day,
            distances: distances,
            paths: distances.map { _ in Geo.lineCoordinates(metres: 1000, count: 11) },
            calendar: Clock.calendar
        )
    }

    func testArrivalFollowsFromDistanceAndSpeed() {
        // 6 km at 60 km/h leaving 09:00 arrives 09:06.
        let built = schedule(
            distances: [6000],
            stops: [stop("home", departure: 9 * 60, speed: 60), stop("work", departure: nil)]
        )

        XCTAssertEqual(built.legs.count, 1)
        XCTAssertEqual(built.legs[0].departure, Clock.time(9, 0))
        XCTAssertEqual(built.legs[0].arrival.timeIntervalSince(Clock.time(9, 6)), 0, accuracy: 1)
        XCTAssertFalse(built.legs[0].isLate)
        XCTAssertFalse(built.hasSlippedLegs)
    }

    func testOverrunPushesTheNextDepartureInsteadOfClippingTheLeg() {
        // Leg one takes 90 minutes but the next departure was planned 30 minutes in.
        let built = schedule(
            distances: [90_000, 6000],
            stops: [
                stop("a", departure: 9 * 60, speed: 60),
                stop("b", departure: 9 * 60 + 30, speed: 60),
                stop("c", departure: nil),
            ]
        )

        XCTAssertEqual(built.legs[0].arrival.timeIntervalSince(Clock.time(10, 30)), 0, accuracy: 1)
        // The slipped departure leaves on arrival, not at its planned time — and says so.
        XCTAssertEqual(built.legs[1].departure, built.legs[0].arrival)
        XCTAssertTrue(built.legs[1].isLate)
        XCTAssertEqual(built.legs[1].plannedDeparture, Clock.time(9, 30))
        XCTAssertTrue(built.hasSlippedLegs)
    }

    func testPositionTracksTheClockThroughTheDay() {
        let built = schedule(
            distances: [6000],
            stops: [stop("home", departure: 9 * 60, speed: 60), stop("work", departure: nil)]
        )

        // Before departure: parked at the first stop, until the departure.
        guard case .atStop(let index, let until) = built.position(at: Clock.time(8, 0))! else {
            return XCTFail("expected atStop before departure")
        }
        XCTAssertEqual(index, 0)
        XCTAssertEqual(until, Clock.time(9, 0))

        // Halfway through the six-minute drive: travelling leg 0 at fraction 0.5.
        guard case .travelling(let leg, let fraction) = built.position(at: Clock.time(9, 3))! else {
            return XCTFail("expected travelling mid-leg")
        }
        XCTAssertEqual(leg, 0)
        XCTAssertEqual(fraction, 0.5, accuracy: 0.01)

        // Long after arrival: parked at the last stop for good.
        guard case .atStop(let lastIndex, let lastUntil) = built.position(at: Clock.time(23, 0))! else {
            return XCTFail("expected atStop after the day is done")
        }
        XCTAssertEqual(lastIndex, 1)
        XCTAssertNil(lastUntil)
    }

    func testInterpolateWalksByDistanceNotByIndex() {
        // Vertices at 0, 100 and 1000 metres. Halfway by distance is 500 m — between
        // the second and third vertices — while halfway by index would sit at 100 m.
        let base = Geo.line(metres: 1000, count: 11)
        let uneven = [base[0], base[1], base[10]].map(Coordinate.init)

        let midpoint = DaySchedule.interpolate(uneven, fraction: 0.5)!
        let expected = Geo.line(metres: 1000, count: 3)[1]   // the true 500 m point
        XCTAssertLessThanOrEqual(Geo.distance(midpoint, expected), 2)
    }

    func testRemainderResumesMidLegWithoutReplayingIt() {
        let path = Geo.lineCoordinates(metres: 1000, count: 3)   // A, midpoint, B

        // Untouched at the start, a single point at the end.
        XCTAssertEqual(DayPlanRunner.remainder(of: path, from: 0), path)
        XCTAssertEqual(DayPlanRunner.remainder(of: path, from: 1).count, 1)

        // Joining halfway: starts at the midpoint (interpolated), keeps the tail.
        let remainder = DayPlanRunner.remainder(of: path, from: 0.5)
        XCTAssertLessThanOrEqual(
            Geo.distance(remainder.first!.clCoordinate, path[1].clCoordinate), 2)
        XCTAssertEqual(remainder.last, path.last)
    }
}
