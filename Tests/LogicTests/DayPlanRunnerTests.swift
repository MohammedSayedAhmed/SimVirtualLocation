import CoreLocation
import XCTest
@testable import SimVLLogic

/// The runner decides, tick by tick, whether the device should be parked or driving.
/// Its two subtle rules — park early rather than replay the last few seconds, and tell
/// a leg that has not started yet from one that has died — were previously only
/// observable by running a real plan on a real phone.
final class DayPlanRunnerTests: XCTestCase {

    private var clock = Clock.time(8, 0)
    private var held: [CLLocationCoordinate2D] = []
    private var played: [(path: [Coordinate], speed: Double, duration: TimeInterval)] = []
    private var legSessionAlive = true

    private func makeRunner() -> DayPlanRunner {
        let runner = DayPlanRunner()
        runner.now = { [unowned self] in self.clock }
        runner.holdPoint = { [unowned self] in self.held.append($0) }
        runner.playLeg = { [unowned self] path, speed, duration in
            self.played.append((path, speed, duration))
        }
        runner.isLegSessionAlive = { [unowned self] in self.legSessionAlive }
        return runner
    }

    /// Home at 09:00 → work, 6 km at 60 km/h, arriving 09:06.
    private func makeSchedule() -> DaySchedule {
        let stops = [
            DayPlanStop(name: "home", latitude: Geo.baseLatitude, longitude: Geo.baseLongitude,
                        departureMinutes: 9 * 60, speedKph: 60),
            DayPlanStop(name: "work", latitude: Geo.baseLatitude, longitude: Geo.baseLongitude,
                        departureMinutes: nil),
        ]
        return DaySchedule.build(
            plan: DayPlan(stops: stops),
            on: Clock.day,
            distances: [6000],
            paths: [Geo.lineCoordinates(metres: 6000, count: 61)],
            calendar: Clock.calendar
        )
    }

    override func setUp() {
        super.setUp()
        clock = Clock.time(8, 0)
        held = []
        played = []
        legSessionAlive = true
    }

    func testParksAtTheFirstStopBeforeDeparture() {
        let runner = makeRunner()
        runner.start(makeSchedule())

        XCTAssertEqual(held.count, 1, "before leaving, the device sits at the first stop")
        XCTAssertTrue(played.isEmpty)
        guard case .waiting(let index, let until) = runner.activity else {
            return XCTFail("expected waiting, got \(runner.activity)")
        }
        XCTAssertEqual(index, 0)
        XCTAssertEqual(until, Clock.time(9, 0))
    }

    func testStartsTheLegOnceAndOnlyOnce() {
        let runner = makeRunner()
        runner.start(makeSchedule())

        clock = Clock.time(9, 1)
        runner.tick()
        XCTAssertEqual(played.count, 1, "the leg starts when the clock says to")

        // Re-issuing every tick would tear down the session mid-drive.
        for second in 2...20 {
            clock = Clock.time(9, 1, second: second)
            runner.tick()
        }
        XCTAssertEqual(played.count, 1, "a running leg must not be restarted by ticking")
    }

    func testPlaysOnlyTheRemainderWhenJoiningMidLeg() {
        // Resuming after a disconnect must continue from where the clock is, not replay.
        let runner = makeRunner()
        runner.start(makeSchedule())

        clock = Clock.time(9, 3)   // halfway through a six-minute drive
        runner.tick()

        XCTAssertEqual(played.count, 1)
        let remainder = played[0].path
        let full = Geo.lineCoordinates(metres: 6000, count: 61)
        XCTAssertLessThan(remainder.count, full.count, "joining halfway plays less than the whole leg")
        XCTAssertEqual(remainder.last, full.last, "but still finishes at the destination")
        XCTAssertEqual(played[0].duration, 180, accuracy: 2, "and is given the time that is left")
    }

    func testParksAtTheDestinationWhenAlmostThere() {
        // Inside the arrival floor, restarting the last seconds of movement is more
        // visible than simply being there — this is what stopped the day plan
        // teleporting when a leg was re-issued moments before arrival.
        let runner = makeRunner()
        runner.start(makeSchedule())

        clock = Clock.time(9, 5, second: 45)   // 15s from arrival, under the 30s floor
        runner.tick()

        XCTAssertTrue(played.isEmpty, "no drive is issued this close to arriving")
        XCTAssertEqual(held.count, 2, "the destination is held instead")
    }

    func testADeadLegIsReissuedButOnlyAfterTheGrace() {
        let runner = makeRunner()
        runner.start(makeSchedule())

        clock = Clock.time(9, 1)
        runner.tick()
        XCTAssertEqual(played.count, 1)

        // A helper that has not started yet reads exactly like one that has stopped.
        legSessionAlive = false
        clock = Clock.time(9, 1, second: 5)
        runner.tick()
        XCTAssertEqual(played.count, 1, "inside the grace, 'no session' means 'not yet'")

        // Past the grace, it means the drive really did die.
        clock = Clock.time(9, 1, second: 15)
        runner.tick()
        XCTAssertEqual(played.count, 2, "past the grace, a dead leg is picked back up")
    }

    func testHoldsTheLastStopOnceTheDayIsDone() {
        let runner = makeRunner()
        runner.start(makeSchedule())

        clock = Clock.time(12, 0)
        runner.tick()

        guard case .waiting(let index, let until) = runner.activity else {
            return XCTFail("expected waiting at the end of the day")
        }
        XCTAssertEqual(index, 1)
        XCTAssertNil(until, "the last stop is for the rest of the day")
        XCTAssertEqual(held.last?.latitude, Geo.baseLatitude)
    }

    func testStoppingEndsIt() {
        let runner = makeRunner()
        runner.start(makeSchedule())
        XCTAssertTrue(runner.isRunning)

        runner.stop()
        XCTAssertFalse(runner.isRunning)
        XCTAssertEqual(runner.activity, .stopped)

        let before = played.count + held.count
        clock = Clock.time(9, 1)
        runner.tick()
        XCTAssertEqual(played.count + held.count, before, "a stopped plan does nothing")
    }
}
