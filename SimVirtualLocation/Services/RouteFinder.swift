import CoreLocation
import Foundation
import MapKit

/// Looks up the driving or walking route between two points.
///
/// A day plan needs the real road distance for every leg before it can say when you will
/// arrive anywhere, so this is the step that turns a list of places into a timetable.
enum RouteFinder {

    struct Leg {
        let distance: CLLocationDistance
        let path: [Coordinate]
    }

    enum Failure: LocalizedError {
        case noRoute

        var errorDescription: String? {
            "No route between those two points."
        }
    }

    static func route(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        transportType: TransportType
    ) async throws -> Leg {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = transportType == .driving ? .automobile : .walking

        let response = try await MKDirections(request: request).calculate()

        guard let route = response.routes.first else { throw Failure.noRoute }

        let polyline = route.polyline
        let buffer = UnsafeBufferPointer(start: polyline.points(), count: polyline.pointCount)
        let path = buffer.map { Coordinate($0.coordinate) }

        return Leg(distance: route.distance, path: path)
    }
}
