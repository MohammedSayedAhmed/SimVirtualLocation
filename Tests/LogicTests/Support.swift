import CoreLocation
import XCTest
@testable import SimVLLogic

/// Shared geometry for the tests: straight lines of coordinates along a meridian, so
/// every distance is checkable against CLLocation's own arithmetic rather than a
/// hand-derived constant.
enum Geo {

    static let baseLatitude = 25.0
    static let baseLongitude = 51.5

    /// `count` evenly spaced points spanning `metres` due north from the base point.
    static func line(metres: CLLocationDistance, count: Int) -> [CLLocationCoordinate2D] {
        let degrees = metres / metresPerDegreeLatitude
        return (0..<count).map { index in
            CLLocationCoordinate2D(
                latitude: baseLatitude + degrees * Double(index) / Double(count - 1),
                longitude: baseLongitude
            )
        }
    }

    static func lineCoordinates(metres: CLLocationDistance, count: Int) -> [Coordinate] {
        line(metres: metres, count: count).map(Coordinate.init)
    }

    /// Metres in one degree of latitude at the base point, measured, not assumed.
    static let metresPerDegreeLatitude: CLLocationDistance = CLLocation.distance(
        from: CLLocationCoordinate2D(latitude: baseLatitude, longitude: baseLongitude),
        to: CLLocationCoordinate2D(latitude: baseLatitude + 1, longitude: baseLongitude)
    )

    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation.distance(from: a, to: b)
    }
}

/// A UTC gregorian calendar and a fixed day, so results do not depend on the machine
/// the tests run on.
enum Clock {
    static var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// An arbitrary fixed day (2026-03-10, a Tuesday).
    static let day: Date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12))!

    static func time(_ hour: Int, _ minute: Int, second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: hour, minute: minute, second: second))!
    }
}
