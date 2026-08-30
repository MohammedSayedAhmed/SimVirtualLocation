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

    /// How long a freshly issued leg is given to get its session up before that session
    /// is believed to be dead. Launching the helper is not instant, and asking too soon
    /// reads as "already gone" and restarts a leg that was only just starting.
    private static let legStartGrace: TimeInterval = 10

    /// A leg with less than this left to run is parked at its destination rather than
    /// re-issued. Replaying the last few seconds of movement is more visible than simply
    /// arriving early and waiting for the clock to catch up.
    private static let arrivalFloor: TimeInterval = 30

    /// Hold a fixed point (used while parked at a stop).
    var holdPoint: ((CLLocationCoordinate2D) -> Void)?

    /// Play the remainder of a leg: the path still to cover, at this speed in km/h, and
    /// how many seconds remain before it is due to arrive. The last of those matters
    /// because a realistic drive is shaped to fit the time it has rather than run at a
    /// fixed speed — the plan's arrival times stay exact either way.
    var playLeg: (([Coordinate], Double, TimeInterval) -> Void)?

    /// Where "now" comes from.
    ///
    /// Every decision this makes is a comparison against the wall clock, which made the
    /// behaviour that matters most — parking early, telling a leg that has not started
    /// from one that has died — impossible to check without a phone and a stopwatch.
    /// Production leaves this alone; tests move time on purpose.
    var now: () -> Date = Date.init

    /// Whether the session driving the current leg is still up.
    ///
    /// A leg is one long-lived playback session, and a held point has a supervisor
    /// watching its own session for exactly this reason. A leg had nothing: if its
    /// session ended early the device simply stopped moving, silently, until the next
    /// leg boundary came round. The clock is the truth, so a dead session means the
    /// remainder gets re-issued from wherever the day has got to by now.
    var isLegSessionAlive: (() -> Bool)?

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

    /// When the current leg's session was last asked for, so a session that has not had
    /// time to come up yet is not mistaken for one that has died.
    private var legIssuedAt: Date?

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
        legIssuedAt = nil
        activity = .stopped
        log?("Day plan stopped")
        onFinished?()
    }

    /// Re-issues whatever should be happening right now. Used after the device comes
    /// back, where the session that was playing the current leg died with the cable.
    func resume() {
        guard schedule != nil else { return }
        log?("Day plan resuming after an interruption")
        legIssuedAt = nil
        activity = .stopped
        tick()
    }

    // MARK: - Private

    /// Re-decides what should be happening. Internal rather than private so the tests
    /// can drive it directly instead of waiting on a two-second timer.
    func tick() {
        guard let schedule else { return }
        guard let position = schedule.position(at: now()) else { return }

        switch position {
        case .atStop(let index, let until):
            guard activity != .waiting(stopIndex: index, until: until) else { return }
            guard schedule.stops.indices.contains(index) else { return }

            let stop = schedule.stops[index]
            log?("Day plan: at \(stop.name)" + (until.map { " until \(Self.time($0))" } ?? " for the rest of the day"))
            legIssuedAt = nil
            activity = .waiting(stopIndex: index, until: until)
            holdPoint?(stop.coordinate)

        case .travelling(let legIndex, let fraction):
            guard schedule.legs.indices.contains(legIndex) else { return }
            let leg = schedule.legs[legIndex]
            let destination = schedule.stops[min(leg.fromIndex + 1, schedule.stops.count - 1)]

            // Only start a leg once. Re-issuing every tick would tear down the session
            // playing it and restart from the current point, which is the stutter this
            // app already learned to avoid with a held point. The one thing worth
            // re-issuing for is a session that is no longer there.
            if case .travelling(let running, _) = activity, running == legIndex {
                guard hasLostLegSession() else { return }
                log?("Day plan: the session driving this leg ended early — picking the leg up from where the day is now")
            }

            // Close enough to arriving that restarting the last of the movement would be
            // more noticeable than simply being there: park at the destination and let
            // the clock catch up.
            let untilArrival = leg.arrival.timeIntervalSince(now())
            let remaining = Self.remainder(of: leg.path, from: fraction)
            guard remaining.count > 1, untilArrival > Self.arrivalFloor else {
                activity = .travelling(legIndex: legIndex, arrival: leg.arrival)
                legIssuedAt = now()
                holdPoint?(destination.coordinate)
                return
            }

            let from = schedule.stops[leg.fromIndex].name
            log?("Day plan: \(from) → \(destination.name), arriving \(Self.time(leg.arrival))")

            activity = .travelling(legIndex: legIndex, arrival: leg.arrival)
            legIssuedAt = now()
            playLeg?(remaining, leg.speedKph, untilArrival)
        }
    }

    /// Whether the leg currently marked as running has lost the session playing it.
    ///
    /// A leg that has only just been issued is left alone: the helper takes a moment to
    /// come up, and during that moment "not running" means "not yet", not "no longer".
    private func hasLostLegSession() -> Bool {
        guard let isLegSessionAlive else { return false }
        guard let legIssuedAt, now().timeIntervalSince(legIssuedAt) >= Self.legStartGrace else { return false }
        return !isLegSessionAlive()
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
