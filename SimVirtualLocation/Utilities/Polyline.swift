import CoreLocation
import Foundation

/// Geometry over a path of coordinates.
///
/// Both GPX writing and the drive profile need to walk a polyline by distance, and route
/// playback needs to find where along the route the device currently is. One copy of the
/// arithmetic, so a fix to it cannot miss a twin.
enum Polyline {

    /// Distance from the start of `path` to each of its vertices. First entry is 0.
    static func cumulativeDistances(_ path: [CLLocationCoordinate2D]) -> [CLLocationDistance] {
        var cumulative: [CLLocationDistance] = [0]
        cumulative.reserveCapacity(path.count)
        for index in 1..<max(path.count, 1) {
            cumulative.append(cumulative[index - 1] + CLLocation.distance(from: path[index - 1], to: path[index]))
        }
        return cumulative
    }

    /// `path` re-emitted as points a fixed `step` apart, ending on the original endpoint.
    ///
    /// Route polylines put vertices where the road bends, so a long straight is two points
    /// hundreds of metres apart — useless for anything that works per-distance.
    static func resample(_ path: [CLLocationCoordinate2D], step: CLLocationDistance) -> [CLLocationCoordinate2D] {
        guard path.count > 1, step > 0 else { return path }

        let cumulative = cumulativeDistances(path)
        guard let total = cumulative.last, total > step else { return path }

        var result: [CLLocationCoordinate2D] = []
        result.reserveCapacity(Int(total / step) + 2)

        var travelled: CLLocationDistance = 0
        var segment = 0
        while travelled < total {
            while segment < cumulative.count - 2, cumulative[segment + 1] < travelled { segment += 1 }
            let start = cumulative[segment]
            let span = cumulative[segment + 1] - start
            let fraction = span > 0 ? (travelled - start) / span : 0
            let from = path[segment]
            let to = path[segment + 1]
            result.append(
                CLLocationCoordinate2D(
                    latitude: from.latitude + (to.latitude - from.latitude) * fraction,
                    longitude: from.longitude + (to.longitude - from.longitude) * fraction
                )
            )
            travelled += step
        }
        if let last = path.last { result.append(last) }
        return result
    }

    /// Index of the vertex of `path` closest to `point`.
    ///
    /// Meant for a finely resampled path, where the nearest vertex is within a step of
    /// the true nearest point; on a raw polyline it can be off by a whole straight.
    static func nearestVertex(to point: CLLocationCoordinate2D, in path: [CLLocationCoordinate2D]) -> Int {
        var best = 0
        var bestDistance = CLLocationDistance.greatestFiniteMagnitude
        for (index, vertex) in path.enumerated() {
            let distance = CLLocation.distance(from: point, to: vertex)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }
}
