import CoreLocation
import Foundation

/// Where along a route the device has got to, kept up to date as the route is played.
///
/// Two decisions hang off this: where to cut the route when playback restarts (a speed
/// change, the device coming back), and whether the drive is over. Both used to be a
/// nearest-vertex search over the whole route plus a count of vertices left, and both
/// went wrong in the field. The global search picks the wrong pass on any route that
/// comes near itself — out and back on the same road, a loop home — and the vertex
/// count read a finished drive whose last report sat a few metres short of the final
/// vertex as "two more to go", replaying nothing and never holding the destination.
///
/// Progress here only moves forward, and the end of the route is a distance.
struct RouteProgress {

    /// The route, finely and evenly resampled. Never rebased: a restart cuts from it.
    let path: [CLLocationCoordinate2D]

    /// Distance from the start to each vertex of `path`.
    let cumulative: [CLLocationDistance]

    /// The vertex the device was last nearest to.
    private(set) var index = 0

    /// The last point the device reported, if it has reported one.
    private(set) var position: CLLocationCoordinate2D?

    /// How far behind the last vertex a report may land and still count. The played
    /// file's points sit between the route's vertices, so being nearest to the one
    /// just passed is ordinary; being nearest to one further back is not movement.
    static let lookBehind = 3

    /// How far ahead one report may carry progress. Reports arrive several times a
    /// second, so this is generous for real movement; it is here so a route that comes
    /// back past an earlier stretch cannot be taken for having skipped there.
    static let lookAhead = 100

    init(path: [CLLocationCoordinate2D]) {
        self.path = path
        self.cumulative = Polyline.cumulativeDistances(path)
    }

    var total: CLLocationDistance { cumulative.last ?? 0 }

    var travelled: CLLocationDistance { cumulative.indices.contains(index) ? cumulative[index] : 0 }

    var remainingDistance: CLLocationDistance { max(0, total - travelled) }

    /// The share of the whole route still ahead, for sharing out a journey-time estimate.
    var remainingFraction: Double { total > 0 ? remainingDistance / total : 1 }

    /// The route from the current vertex to the end.
    var remainingPath: [CLLocationCoordinate2D] {
        guard path.indices.contains(index) else { return [] }
        return Array(path[index...])
    }

    var start: CLLocationCoordinate2D? { path.first }
    var destination: CLLocationCoordinate2D? { path.last }

    /// Whether what is left is too little to be worth driving.
    func hasArrived(within tolerance: CLLocationDistance) -> Bool {
        remainingDistance <= tolerance
    }

    /// The device reported being at `coordinate`.
    mutating func advance(to coordinate: CLLocationCoordinate2D) {
        position = coordinate
        guard !path.isEmpty else { return }
        index = Polyline.nearestVertex(
            to: coordinate,
            in: path,
            near: index,
            lookBehind: Self.lookBehind,
            lookAhead: Self.lookAhead
        )
    }
}
