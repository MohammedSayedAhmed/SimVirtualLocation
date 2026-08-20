import CoreLocation
import Foundation

/// One place in a day, and when to leave it.
///
/// A plan is just an ordered list of these: the travel between them is derived rather
/// than entered, because the thing you actually know is where you are going and how fast
/// you intend to get there — the arrival time follows from that.
struct DayPlanStop: Identifiable, Codable, Equatable {

    var id: UUID = UUID()
    var name: String
    var latitude: Double
    var longitude: Double

    /// Minutes from midnight at which to leave. `nil` for the last stop: you stay.
    var departureMinutes: Int?

    /// Speed for the leg that leaves this stop, km/h.
    var speedKph: Double = 60

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    static func minutes(hour: Int, minute: Int) -> Int { hour * 60 + minute }

    static func formatted(minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

struct DayPlan: Codable, Equatable {
    var stops: [DayPlanStop] = []

    var isRunnable: Bool { stops.count >= 1 }
}

/// A leg after the schedule has been worked out against real clock times.
struct ScheduledLeg: Equatable {
    /// Index of the stop being left.
    let fromIndex: Int
    let departure: Date
    let arrival: Date
    let distance: CLLocationDistance
    let speedKph: Double

    /// The route this leg follows, already resampled for playback.
    let path: [Coordinate]

    /// True when the previous leg arrived after this one was due to leave, so this
    /// departure has slipped. The plan still runs; the slip is reported rather than
    /// silently absorbed.
    let isLate: Bool

    /// What the plan asked for, kept so the UI can show the difference.
    let plannedDeparture: Date
}

/// A plan resolved against a particular day.
struct DaySchedule: Equatable {

    /// Where the device should be at a given instant.
    enum Position: Equatable {
        /// Sitting at a stop, leaving at `until` (`nil` means staying put for good).
        case atStop(index: Int, until: Date?)
        /// Part-way along a leg. `fraction` is 0…1 of the way there.
        case travelling(legIndex: Int, fraction: Double)
    }

    let stops: [DayPlanStop]
    let legs: [ScheduledLeg]

    var hasSlippedLegs: Bool { legs.contains { $0.isLate } }

    /// Resolve `plan` against `day`, given each leg's routed distance and path.
    ///
    /// A leg that overruns the next departure pushes it later rather than being clipped:
    /// the day still plays out in order, just behind schedule, which is what actually
    /// happens when you take longer to get somewhere than you meant to.
    static func build(
        plan: DayPlan,
        on day: Date,
        distances: [CLLocationDistance],
        paths: [[Coordinate]],
        calendar: Calendar = .current
    ) -> DaySchedule {
        let midnight = calendar.startOfDay(for: day)
        var legs: [ScheduledLeg] = []
        var previousArrival: Date?

        for index in 0..<max(plan.stops.count - 1, 0) {
            let stop = plan.stops[index]
            guard let departureMinutes = stop.departureMinutes else { break }
            guard index < distances.count, index < paths.count else { break }

            let planned = midnight.addingTimeInterval(TimeInterval(departureMinutes * 60))
            let departure: Date
            let isLate: Bool

            if let previousArrival, previousArrival > planned {
                departure = previousArrival
                isLate = true
            } else {
                departure = planned
                isLate = false
            }

            let metresPerSecond = max(stop.speedKph, 1) / 3.6
            let arrival = departure.addingTimeInterval(distances[index] / metresPerSecond)

            legs.append(
                ScheduledLeg(
                    fromIndex: index,
                    departure: departure,
                    arrival: arrival,
                    distance: distances[index],
                    speedKph: stop.speedKph,
                    path: paths[index],
                    isLate: isLate,
                    plannedDeparture: planned
                )
            )

            previousArrival = arrival
        }

        return DaySchedule(stops: plan.stops, legs: legs)
    }

    /// Where the device should be at `instant`, or `nil` when there is no plan at all.
    func position(at instant: Date) -> Position? {
        guard !stops.isEmpty else { return nil }
        guard let first = legs.first else {
            return .atStop(index: 0, until: nil)
        }

        if instant < first.departure {
            return .atStop(index: 0, until: first.departure)
        }

        for (offset, leg) in legs.enumerated() {
            if leg.departure <= instant, instant < leg.arrival {
                let span = leg.arrival.timeIntervalSince(leg.departure)
                let travelled = instant.timeIntervalSince(leg.departure)
                return .travelling(legIndex: offset, fraction: span > 0 ? travelled / span : 1)
            }

            let next = offset + 1 < legs.count ? legs[offset + 1] : nil

            if instant >= leg.arrival, next == nil || instant < next!.departure {
                return .atStop(index: leg.fromIndex + 1, until: next?.departure)
            }
        }

        return .atStop(index: stops.count - 1, until: nil)
    }

    /// The coordinate for a position, interpolated along the leg while travelling.
    func coordinate(for position: Position) -> CLLocationCoordinate2D? {
        switch position {
        case .atStop(let index, _):
            guard stops.indices.contains(index) else { return nil }
            return stops[index].coordinate

        case .travelling(let legIndex, let fraction):
            guard legs.indices.contains(legIndex) else { return nil }
            return Self.interpolate(legs[legIndex].path, fraction: fraction)
        }
    }

    /// Point `fraction` of the way along `path`, by distance rather than by index, so an
    /// unevenly sampled route still moves at a steady speed.
    static func interpolate(_ path: [Coordinate], fraction: Double) -> CLLocationCoordinate2D? {
        guard let first = path.first else { return nil }
        guard path.count > 1 else { return first.clCoordinate }

        var cumulative: [CLLocationDistance] = [0]
        for index in 1..<path.count {
            let step = CLLocation.distance(
                from: path[index - 1].clCoordinate,
                to: path[index].clCoordinate
            )
            cumulative.append(cumulative[index - 1] + step)
        }

        guard let total = cumulative.last, total > 0 else { return first.clCoordinate }

        let target = min(max(fraction, 0), 1) * total

        for index in 1..<cumulative.count where cumulative[index] >= target {
            let spanStart = cumulative[index - 1]
            let span = cumulative[index] - spanStart
            let within = span > 0 ? (target - spanStart) / span : 0
            let from = path[index - 1]
            let to = path[index]
            return CLLocationCoordinate2D(
                latitude: from.latitude + (to.latitude - from.latitude) * within,
                longitude: from.longitude + (to.longitude - from.longitude) * within
            )
        }

        return path[path.count - 1].clCoordinate
    }
}
