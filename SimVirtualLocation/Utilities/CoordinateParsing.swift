import CoreLocation
import Foundation

enum CoordinateParsing {
    /// Valid geographic ranges; allows negative (west/south) coordinates.
    static func isValid(latitude: Double, longitude: Double) -> Bool {
        latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180
    }
}

extension CLLocation {

    /// Great-circle distance between two coordinates, in metres.
    ///
    /// Lives here rather than in the controller because everything that walks a
    /// polyline uses it — and so the pure-logic test package can compile it without
    /// dragging the whole controller along.
    static func distance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> CLLocationDistance {
        let from = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let to = CLLocation(latitude: to.latitude, longitude: to.longitude)
        return from.distance(from: to)
    }
}
