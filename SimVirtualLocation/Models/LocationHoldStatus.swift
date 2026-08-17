import CoreLocation
import Foundation

/// Plain, `Equatable` coordinate. `CLLocationCoordinate2D` is not `Equatable`, and the
/// hold status has to be diffable so the UI only refreshes on real changes.
struct Coordinate: Equatable, Hashable {

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

    var formatted: String {
        String(format: "%.6f, %.6f", latitude, longitude)
    }
}

/// Result of a single attempt to push a coordinate to the selected target.
enum InjectionOutcome: Equatable {

    /// The coordinate was applied and the helper finished cleanly.
    case success

    /// The coordinate was applied and a long-lived helper process is holding the
    /// device session open. On iOS 17+ (DVT over RSD) the simulated location only
    /// survives while that process runs, so it must be kept alive, not killed.
    case holding

    /// The coordinate was not applied. `reason` is shown to the user verbatim.
    case failure(reason: String)

    var isSuccess: Bool {
        switch self {
        case .success, .holding:
            return true
        case .failure:
            return false
        }
    }

    var failureReason: String? {
        guard case .failure(let reason) = self else { return nil }
        return reason
    }
}

/// What the app is actually able to promise about the simulated location right now.
///
/// The whole point of this type is that a "location is set" state is only reachable
/// from a *confirmed* injection. The previous UI reported simulation as on based on a
/// flag that nothing ever cleared, so a location that had silently reverted to real
/// GPS still looked applied.
enum LocationHoldStatus: Equatable {

    enum Severity {
        case neutral
        case ok
        case warning
        case error
    }

    /// Nothing is being held — the device is on its own real location.
    case idle

    /// The first attempt is in flight; nothing is confirmed yet.
    case applying(coordinate: Coordinate?)

    /// A fixed point is applied and was last confirmed at `confirmedAt`.
    case holding(coordinate: Coordinate, confirmedAt: Date, viaLiveSession: Bool)

    /// A route is being played back; `confirmedAt` is the last accepted update.
    case route(confirmedAt: Date)

    /// An attempt failed, but the point was applied recently and is being retried.
    case recovering(coordinate: Coordinate?, reason: String, failures: Int, lastConfirmedAt: Date?)

    /// The hold is broken. The device is back on its real location.
    case lost(coordinate: Coordinate?, reason: String, lastConfirmedAt: Date?)

    /// A point was applied, but nothing is re-checking it. It can revert at any
    /// moment without the app noticing — never shown as healthy.
    case unverified(coordinate: Coordinate, appliedAt: Date)

    var severity: Severity {
        switch self {
        case .idle:
            return .neutral
        case .applying:
            return .neutral
        case .holding, .route:
            return .ok
        case .recovering, .unverified:
            return .warning
        case .lost:
            return .error
        }
    }

    /// `true` while the app is trying to keep something applied, healthy or not.
    var isActive: Bool {
        switch self {
        case .idle:
            return false
        case .applying, .holding, .route, .recovering, .lost, .unverified:
            return true
        }
    }

    /// `true` only when the location is confirmed applied. Never guess here.
    var isConfirmed: Bool {
        switch self {
        case .holding, .route:
            return true
        case .idle, .applying, .recovering, .lost, .unverified:
            return false
        }
    }

    var coordinate: Coordinate? {
        switch self {
        case .applying(let coordinate):
            return coordinate
        case .holding(let coordinate, _, _):
            return coordinate
        case .recovering(let coordinate, _, _, _), .lost(let coordinate, _, _):
            return coordinate
        case .unverified(let coordinate, _):
            return coordinate
        case .idle, .route:
            return nil
        }
    }

    var confirmedAt: Date? {
        switch self {
        case .holding(_, let date, _), .route(let date):
            return date
        case .recovering(_, _, _, let date), .lost(_, _, let date):
            return date
        case .unverified(_, let date):
            return date
        case .idle, .applying:
            return nil
        }
    }

    var reason: String? {
        switch self {
        case .recovering(_, let reason, _, _), .lost(_, let reason, _):
            return reason
        case .idle, .applying, .holding, .route, .unverified:
            return nil
        }
    }

    var title: String {
        switch self {
        case .idle:
            return "No simulated location"
        case .applying:
            return "Applying location…"
        case .holding:
            return "Location held"
        case .route:
            return "Simulating route"
        case .recovering:
            return "Location may have dropped — retrying"
        case .lost:
            return "LOCATION NOT SET — the device is on its real GPS"
        case .unverified:
            return "Applied once — NOT being kept alive"
        }
    }

    var detail: String? {
        switch self {
        case .idle:
            return "Pick a point on the map, then use Set to A / Set to Coordinate."

        case .applying(let coordinate):
            return coordinate.map { "\($0.formatted) — waiting for the device to confirm" }
                ?? "Waiting for the device to confirm"

        case .holding(let coordinate, let confirmedAt, let viaLiveSession):
            let confirmation = viaLiveSession
                ? "device session alive, checked"
                : "re-applied"
            return "\(coordinate.formatted) — \(confirmation) at \(Self.time(confirmedAt))"

        case .route(let confirmedAt):
            return "Last position accepted at \(Self.time(confirmedAt))"

        case .recovering(let coordinate, let reason, let failures, let lastConfirmedAt):
            let attempt = failures == 1 ? "1 failed attempt" : "\(failures) failed attempts"
            let last = lastConfirmedAt.map { "last confirmed \(Self.time($0))" } ?? "never confirmed"
            let point = coordinate.map { "\($0.formatted) — " } ?? ""
            return "\(point)\(attempt), \(last). \(reason)"

        case .lost(let coordinate, let reason, let lastConfirmedAt):
            let last = lastConfirmedAt.map { "Last confirmed \(Self.time($0))." } ?? "It was never confirmed."
            let point = coordinate.map { "\($0.formatted). " } ?? ""
            return "\(point)\(last) \(reason)"

        case .unverified(let coordinate, let appliedAt):
            return "\(coordinate.formatted) — applied at \(Self.time(appliedAt)). "
                + "Turn on Keep location applied: the device can drop back to real GPS at any time and nothing will notice."
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
}
