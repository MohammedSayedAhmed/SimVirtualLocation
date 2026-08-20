import CoreLocation
import Foundation

/// A plain, comparable coordinate.
///
/// `CLLocationCoordinate2D` is neither `Equatable` nor `Codable`, which makes it unusable
/// in diffable state and in anything that gets saved. This is the value type the app
/// passes around; the CoreLocation one is used only where a framework demands it.
struct Coordinate: Equatable, Hashable, Codable {

    let latitude: Double
    let longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var formatted: String { String(format: "%.6f, %.6f", latitude, longitude) }
}
