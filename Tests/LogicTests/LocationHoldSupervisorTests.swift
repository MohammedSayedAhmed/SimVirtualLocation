import CoreLocation
import XCTest
@testable import SimVLLogic

/// The hold supervisor is the machinery behind the app's one absolute rule: a point
/// that has been set must not quietly stop being in force. Every test here pins a
/// decision that used to be verifiable only by holding a phone and waiting.
final class LocationHoldSupervisorTests: XCTestCase {

    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var applied: [Coordinate] = []
    private var sessionAlive = false
    private var targetAvailable = true

    private let point = CLLocationCoordinate2D(latitude: 25.16, longitude: 51.54)

    /// A supervisor wired to the fake clock and fake device, with the wake observer off.
    private func makeSupervisor() -> LocationHoldSupervisor {
        let supervisor = LocationHoldSupervisor(observesSystemWake: false)
        supervisor.now = { [unowned self] in self.clock }
        supervisor.apply = { [unowned self] coordinate in self.applied.append(Coordinate(coordinate)) }
        supervisor.isSessionAlive = { [unowned self] in self.sessionAlive }
        supervisor.isTargetAvailable = { [unowned self] in self.targetAvailable }
        return supervisor
    }

    private func advance(_ seconds: TimeInterval) { clock.addTimeInterval(seconds) }

    override func setUp() {
        super.setUp()
        clock = Date(timeIntervalSince1970: 1_800_000_000)
        applied = []
        sessionAlive = false
        targetAvailable = true
    }

    // MARK: - The in-flight guard

    func testKeepAliveWaitsForAnApplyThatIsStillStarting() {
        // The bug this prevents: a tunnel takes longer than the keep-alive interval, so
        // the timer fired while the first apply was still spawning, saw no live session,
        // and asked for a second one — two play processes a second apart.
        let supervisor = makeSupervisor()
        supervisor.hold(point)
        XCTAssertEqual(applied.count, 1)

        advance(5)
        supervisor.reapply(trigger: .keepAlive)
        XCTAssertEqual(applied.count, 1, "a keep-alive must not race an apply that is still starting")

        advance(20)
        supervisor.reapply(trigger: .keepAlive)
        XCTAssertEqual(applied.count, 1, "still inside the grace window")
    }

    func testKeepAliveGivesUpOnAnApplyThatNeverArrives() {
        // The counterweight: waiting forever for an apply that died would leave the
        // device on real GPS with the app insisting it was applying.
        let supervisor = makeSupervisor()
        supervisor.hold(point)

        advance(46)   // past applyTimeout
        supervisor.reapply(trigger: .keepAlive)
        XCTAssertEqual(applied.count, 2, "an overdue apply must be retried, not waited on")
    }

    func testAConfirmedApplyIsNoLongerInFlight() {
        let supervisor = makeSupervisor()
        supervisor.hold(point)
        supervisor.confirmApplied()

        // Confirmed and a session is up: the keep-alive should leave it alone entirely.
        sessionAlive = true
        advance(60)
        supervisor.reapply(trigger: .keepAlive)
        XCTAssertEqual(applied.count, 1)
        guard case .held = supervisor.state else { return XCTFail("expected held") }
    }

    // MARK: - Live sessions are the hold

    func testKeepAliveLeavesALiveSessionRunning() {
        // Replacing a live session hands the point back for a second or two — the
        // ping-pong the user filmed. A live session already IS the hold.
        let supervisor = makeSupervisor()
        supervisor.hold(point)
        supervisor.confirmApplied()
        sessionAlive = true

        for _ in 0..<10 {
            advance(15)
            supervisor.reapply(trigger: .keepAlive)
        }
        XCTAssertEqual(applied.count, 1, "a live session must never be torn down by the timer")
    }

    func testASessionThatEndedIsReapplied() {
        let supervisor = makeSupervisor()
        supervisor.hold(point)
        supervisor.confirmApplied()
        sessionAlive = false

        advance(15)
        supervisor.reapply(trigger: .keepAlive)
        XCTAssertEqual(applied.count, 2, "no session means the point is not in force")
    }

    // MARK: - An absent target is never reported as held

    func testAnUnavailableTargetFailsRatherThanClaimingSuccess() {
        let supervisor = makeSupervisor()
        supervisor.hold(point)
        supervisor.confirmApplied()

        targetAvailable = false
        supervisor.unavailableReason = { "No simulator is booted." }
        advance(15)
        supervisor.reapply(trigger: .keepAlive)

        XCTAssertEqual(applied.count, 1, "nothing can be applied to a target that is not there")
        guard case .failed(_, let reason) = supervisor.state else {
            return XCTFail("expected failed, got \(supervisor.state)")
        }
        XCTAssertEqual(reason, "No simulator is booted.", "the reason must name the real target")
    }

    func testTargetRestoredReappliesImmediately() {
        // Waiting for the next tick meant a minute on real GPS after the cable returned.
        let supervisor = makeSupervisor()
        supervisor.hold(point)
        supervisor.confirmApplied()

        targetAvailable = false
        supervisor.targetLost(reason: "Device disconnected")
        XCTAssertEqual(applied.count, 1)

        targetAvailable = true
        sessionAlive = false
        supervisor.targetRestored()
        XCTAssertEqual(applied.count, 2, "the point goes back the moment the device does")
    }

    // MARK: - Lifecycle

    func testReleaseStopsEverything() {
        let supervisor = makeSupervisor()
        supervisor.hold(point)
        XCTAssertTrue(supervisor.isHolding)

        supervisor.release()
        XCTAssertFalse(supervisor.isHolding)

        advance(60)
        supervisor.reapply(trigger: .keepAlive)
        XCTAssertEqual(applied.count, 1, "a released hold must not keep re-applying")
    }

    func testDisablingStopsReapplying() {
        let supervisor = makeSupervisor()
        supervisor.hold(point)
        supervisor.confirmApplied()
        supervisor.isEnabled = false

        advance(60)
        supervisor.reapply(trigger: .keepAlive)
        XCTAssertEqual(applied.count, 1)
    }

    func testIntervalStaysWithinItsBounds() {
        let supervisor = makeSupervisor()
        supervisor.interval = 1
        XCTAssertEqual(supervisor.interval, LocationHoldSupervisor.intervalRange.lowerBound)
        supervisor.interval = 100_000
        XCTAssertEqual(supervisor.interval, LocationHoldSupervisor.intervalRange.upperBound)
    }
}
