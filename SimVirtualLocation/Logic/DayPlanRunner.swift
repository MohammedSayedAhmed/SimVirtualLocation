import CoreLocation
import Foundation

/// Plays a whole day: parks the device at each stop, and drives it between them on the
/// clock rather than on a stopwatch started when you pressed a button.
///
/// The two things it does are already solid on their own — holding a point survives
/// disconnects and re-applies itself, and a leg is played by one session the same way a
/// route is. This only decides which of the two should be happening right now, and
/// switches between them at leg boundaries. Deciding from the wall clock is what lets it
/// pick the day up correctly after a restart, a sleep, or an hour unplugged.
///
/// All members are main-thread only.
final class DayPlanRunner {

    enum Activity: Equatable {
        case stopped
        /// Parked at a stop, leaving at `until` (`nil` = staying there).
        case waiting(stopIndex: Int, until: Date?)
        /// Driving a leg, due to arrive at `arrival`.
        case travelling(legIndex: Int, arrival: Date)
    }

    /// How often the plan is re-checked against the clock. Only boundaries cause work.
    private static let tickInterval: TimeInterval = 2

    /// Hold a fixed point (used while parked at a stop).
    var holdPoint: ((CLLocationCoordinate2D) -> Void)?

    /// Play the remainder of a leg: the path still to cover, at this speed in km/h.
    var playLeg: (([Coordinate], Double) -> Void)?

    /// Called when the plan finishes or is stopped.
    var onFinished: (() -> Void)?

    var onActivityChange: ((Activity) -> Void)?
    var log: ((String) -> Void)?

    private(set) var activity: Activity = .stopped {
        didSet {
            guard activity != oldValue else { return }
            onActivityChange?(activity)
        }
    }

    private(set) var schedule: DaySchedule?
    private var timer: Timer?

    var isRunning: Bool { schedule != nil }

    /// Starts playing `schedule` from wherever the clock says the day currently is.
    func start(_ schedule: DaySchedule) {
        self.schedule = schedule
        activity = .stopped

        log?("Day plan started — \(schedule.stops.count) stops, \(schedule.legs.count) legs")

        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        tick()
    }

    func stop() {
        guard schedule != nil else { return }
        schedule = nil
        timer?.invalidate()
        timer = nil
        activity = .stopped
        log?("Day plan stopped")
        onFinished?()
    }

    /// Re-issues whatever should be happening right now. Used after the device comes
    /// back, where the session that was playing the current leg died with the cable.
    func resume() {
        guard schedule != nil else { return }
        log?("Day plan resuming after an interruption")
        activity = .stopped
        tick()
    }

    // MARK: - Private

    private func tick() {
        guard let schedule else { return }
        guard let position = schedule.position(at: Date()) else { return }

        switch position {
        case .atStop(let index, let until):
            guard activity != .waiting(stopIndex: index, until: until) else { return }
            guard schedule.stops.indices.contains(index) else { return }

            let stop = schedule.stops[index]
            log?("Day plan: at \(stop.name)" + (until.map { " until \(Self.time($0))" } ?? " for the rest of the day"))
            activity = .waiting(stopIndex: index, until: until)
            holdPoint?(stop.coordinate)

        case .travelling(let legIndex, let fraction):
            guard schedule.legs.indices.contains(legIndex) else { return }
            let leg = schedule.legs[legIndex]

            // Only start a leg once. Re-issuing every tick would tear down the session
            // playing it and restart from the current point, which is the stutter this
            // app already learned to avoid with a held point.
            if case .travelling(let running, _) = activity, running == legIndex { return }

            let remaining = Self.remainder(of: leg.path, from: fraction)
            guard remaining.count > 1 else {
                activity = .travelling(legIndex: legIndex, arrival: leg.arrival)
                holdPoint?(schedule.stops[min(leg.fromIndex + 1, schedule.stops.count - 1)].coordinate)
                return
            }

            let from = schedule.stops[leg.fromIndex].name
            let to = schedule.stops[min(leg.fromIndex + 1, schedule.stops.count - 1)].name
            log?("Day plan: \(from) → \(to), arriving \(Self.time(leg.arrival))")

            activity = .travelling(legIndex: legIndex, arrival: leg.arrival)
            playLeg?(remaining, leg.speedKph)
        }
    }

    /// The part of `path` still ahead when you are `fraction` of the way along it.
    ///
    /// Joining part-way through matters more than it sounds: after a restart or a spell
    /// unplugged, the day should carry on from where the clock says it is, not replay the
    /// leg from its beginning.
    static func remainder(of path: [Coordinate], from fraction: Double) -> [Coordinate] {
        guard path.count > 1 else { return path }
        let clamped = min(max(fraction, 0), 1)
        guard clamped > 0 else { return path }
        guard clamped < 1 else { return Array(path.suffix(1)) }

        guard let joining = DaySchedule.interpolate(path, fraction: clamped) else { return path }

        var cumulative: [CLLocationDistance] = [0]
        for index in 1..<path.count {
            cumulative.append(
                cumulative[index - 1]
                    + CLLocation.distance(from: path[index - 1].clCoordinate, to: path[index].clCoordinate)
            )
        }

        guard let total = cumulative.last, total > 0 else { return path }
        let target = clamped * total
        let nextIndex = cumulative.firstIndex { $0 > target } ?? path.count - 1

        return [Coordinate(joining)] + path[nextIndex...]
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func time(_ date: Date) -> String { timeFormatter.string(from: date) }
}
