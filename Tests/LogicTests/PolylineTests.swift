import CoreLocation
import XCTest
@testable import SimVLLogic

/// Polyline geometry underpins the drive profile, GPX resampling, and — the part that
/// bit hardest — cutting a route at the device's reported position after a restart.
final class PolylineTests: XCTestCase {

    func testCumulativeDistancesMatchTheLineTheyMeasure() {
        let path = Geo.line(metres: 2000, count: 21)
        let cumulative = Polyline.cumulativeDistances(path)

        XCTAssertEqual(cumulative.count, path.count)
        XCTAssertEqual(cumulative[0], 0)
        for index in 1..<cumulative.count {
            XCTAssertGreaterThan(cumulative[index], cumulative[index - 1])
        }
        XCTAssertEqual(cumulative.last!, 2000, accuracy: 20)
    }

    func testResampleSpacesPointsEvenlyAndKeepsTheEndpoint() {
        let path = Geo.line(metres: 1000, count: 2)   // one long segment: the worst case
        let resampled = Polyline.resample(path, step: 10)

        XCTAssertGreaterThan(resampled.count, 90)
        for index in 1..<(resampled.count - 1) {
            let gap = Geo.distance(resampled[index - 1], resampled[index])
            XCTAssertEqual(gap, 10, accuracy: 0.5)
        }
        // The original endpoint survives, whatever the spacing arithmetic did.
        XCTAssertEqual(Geo.distance(resampled.last!, path.last!), 0, accuracy: 0.01)
    }

    func testResampleLeavesDegenerateInputsAlone() {
        let single = [CLLocationCoordinate2D(latitude: 1, longitude: 2)]
        XCTAssertEqual(Polyline.resample(single, step: 10).count, 1)

        let short = Geo.line(metres: 5, count: 2)
        XCTAssertEqual(Polyline.resample(short, step: 10).count, 2)

        let path = Geo.line(metres: 100, count: 3)
        XCTAssertEqual(Polyline.resample(path, step: 0).count, 3)
    }

    func testNearestVertexFindsThePlayedPosition() {
        // The restart bug class: an index into one point list used against another.
        // Position-based cutting must find the vertex nearest an arbitrary point.
        let path = Polyline.resample(Geo.line(metres: 1000, count: 2), step: 10)
        let target = Geo.line(metres: 1000, count: 4)[1]   // one third of the way

        let index = Polyline.nearestVertex(to: target, in: path)
        XCTAssertLessThanOrEqual(Geo.distance(path[index], target), 6)
    }

    func testNearestVertexWindowKeepsTheSearchWhereTheDeviceIs() {
        // A there-and-back route whose return leg runs half a step out of phase, so a
        // vertex of the way back lands exactly on a point of the way out. Searching the
        // whole route then answers "you are nearly home" for a device that has just left.
        let out = stride(from: 0.0, through: 1_000.0, by: 10).map(Geo.point(atMetres:))
        let back = stride(from: 995.0, through: 5.0, by: -10).map(Geo.point(atMetres:))
        let path = out + back
        let onTheWayOut = Geo.point(atMetres: 205)

        let unwindowed = Polyline.nearestVertex(to: onTheWayOut, in: path)
        let windowed = Polyline.nearestVertex(
            to: onTheWayOut, in: path, near: 19, lookBehind: 3, lookAhead: 100)

        XCTAssertGreaterThan(unwindowed, path.count - 30, "the global search lands on the way back")
        XCTAssertLessThanOrEqual(windowed, 21, "the windowed search stays on the way out")
        XCTAssertLessThanOrEqual(Geo.distance(path[windowed], onTheWayOut), 6)
    }

    func testNearestVertexClampsAWindowThatRunsOffEitherEnd() {
        let path = Polyline.resample(Geo.line(metres: 200, count: 2), step: 10)

        // Anchored past the end, and anchored before the start, with a window wider than
        // the path — neither may trap or reach outside the array.
        XCTAssertEqual(
            Polyline.nearestVertex(to: path.last!, in: path, near: 9_999, lookBehind: 9_999, lookAhead: 9_999),
            path.count - 1)
        XCTAssertEqual(
            Polyline.nearestVertex(to: path.first!, in: path, near: -5, lookBehind: 9_999, lookAhead: .max),
            0)
    }

    func testNearestVertexOnAnEmptyPathIsHarmless() {
        XCTAssertEqual(Polyline.nearestVertex(to: Geo.line(metres: 10, count: 2)[0], in: []), 0)
    }
}
