import CoreLocation
import XCTest
@testable import SimVLLogic

/// Two field failures live here, one at each end of the same route.
///
/// A drive that had finished was resumed as a zero-length replay, because "how much is
/// left" was counted in vertices and the device's last report sits between them. A drive
/// seventy seconds old was declared finished, because "where am I" searched the whole
/// route and found a later stretch that passes near the start.
final class RouteProgressTests: XCTestCase {

    private let tolerance: CLLocationDistance = 15

    /// Out along a road and back down the same road — an ordinary there-and-back drive.
    ///
    /// The return leg runs half a step out of phase with the outbound one, so a vertex
    /// of the way back sits exactly on a point of the way out. That is the geometry that
    /// broke the old whole-route search: the nearest vertex to a point near the start is
    /// then a vertex near the END, and the route reads as finished when it has barely
    /// begun.
    private func outAndBack() -> [CLLocationCoordinate2D] {
        let out = stride(from: 0.0, through: 2_000.0, by: 10).map(Geo.point(atMetres:))
        let back = stride(from: 1_995.0, through: 5.0, by: -10).map(Geo.point(atMetres:))
        return out + back
    }

    /// The point on the way out that the way back passes straight through.
    private let sharedPoint = Geo.point(atMetres: 205)

    func testProgressStaysNearTheStartOnARouteThatComesBackToIt() {
        let path = outAndBack()
        var progress = RouteProgress(path: path)

        // Seventy seconds into a long drive: a little way out, on the outbound leg.
        for point in path[0...20] { progress.advance(to: point) }
        progress.advance(to: sharedPoint)

        XCTAssertLessThan(progress.index, 25, "the device is still on the way out")
        XCTAssertFalse(progress.hasArrived(within: tolerance),
                       "a route 5% driven has not arrived")
        XCTAssertGreaterThan(progress.remainingDistance, 3_500)

        // What the old whole-route search would have answered, and why it was wrong.
        let unwindowed = Polyline.nearestVertex(to: sharedPoint, in: path)
        XCTAssertGreaterThan(unwindowed, path.count - 30,
                             "the way back passes through here; a global search lands on it")
    }

    func testProgressReachesTheEndWhenTheDriveDoes() {
        let path = outAndBack()
        var progress = RouteProgress(path: path)
        for point in path { progress.advance(to: point) }

        XCTAssertEqual(progress.index, path.count - 1)
        XCTAssertTrue(progress.hasArrived(within: tolerance))
        XCTAssertEqual(progress.remainingDistance, 0, accuracy: 0.5)
    }

    func testArrivalIsMetresShortOfTheFinalVertexToo() {
        // The played file's points are not the route's vertices: the last point the
        // device reports lands somewhere between the last two. Counting vertices called
        // that "still driving" and replayed a route of no length.
        let path = Polyline.resample(Geo.line(metres: 1000, count: 2), step: 10)
        var progress = RouteProgress(path: path)
        for point in path.dropLast() { progress.advance(to: point) }

        XCTAssertLessThan(progress.remainingDistance, tolerance)
        XCTAssertTrue(progress.hasArrived(within: tolerance),
                      "a report one vertex short of the end is an arrival, not a drive")
        XCTAssertLessThan(progress.remainingPath.count, 3)
    }

    func testRemainingFractionSharesOutTheJourney() {
        let path = Polyline.resample(Geo.line(metres: 1000, count: 2), step: 10)
        var progress = RouteProgress(path: path)
        XCTAssertEqual(progress.remainingFraction, 1, accuracy: 0.001)

        for point in path.prefix(51) { progress.advance(to: point) }
        XCTAssertEqual(progress.remainingFraction, 0.5, accuracy: 0.05)

        // The remainder starts where the device is, and ends where the route does.
        let remaining = progress.remainingPath
        XCTAssertEqual(Geo.distance(remaining.first!, progress.position!), 0, accuracy: 0.01)
        XCTAssertEqual(Geo.distance(remaining.last!, path.last!), 0, accuracy: 0.01)
    }

    func testProgressDoesNotRunBackwardsOnAJitteredReport() {
        let path = Polyline.resample(Geo.line(metres: 1000, count: 2), step: 10)
        var progress = RouteProgress(path: path)
        for point in path.prefix(51) { progress.advance(to: point) }
        let reached = progress.index

        // A report from well behind cannot pull progress back to the start of the route.
        progress.advance(to: path[0])
        XCTAssertGreaterThanOrEqual(progress.index, reached - RouteProgress.lookBehind)
    }

    func testAnUnstartedRouteHasAllOfItselfLeft() {
        let path = Polyline.resample(Geo.line(metres: 1000, count: 2), step: 10)
        let progress = RouteProgress(path: path)

        XCTAssertNil(progress.position)
        XCTAssertFalse(progress.hasArrived(within: tolerance))
        XCTAssertEqual(progress.remainingDistance, progress.total, accuracy: 0.5)
        XCTAssertEqual(progress.remainingPath.count, path.count)
    }
}
