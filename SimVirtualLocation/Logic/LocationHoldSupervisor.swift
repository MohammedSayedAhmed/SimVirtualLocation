import AppKit
import CoreLocation
import Foundation

/// Keeps a single simulated point applied for as long as the user asked for it.
///
/// `simulate-location set` parks in `wait_return()` and holds a DVT channel open, and the
/// point outlives that channel — but only for a grace period, after which the device goes
/// back to its real GPS. Nothing re-applied it, so a point set before a drive could
/// silently lapse partway through while the app still looked like it was simulating.
///
/// This re-applies the held point on a timer, and immediately whenever the session that
/// was holding it ends, so a lapse is measured in seconds rather than lasting until
/// someone notices.
///
/// All members are main-thread only.
final class LocationHoldSupervisor {

    enum Trigger: String {
        case initial = "initial set"
        case keepAlive = "keep-alive"
        case sessionEnded = "session ended"
        case systemWake = "Mac woke from sleep"
        case manual = "manual re-apply"
    }

    static let defaultInterval: TimeInterval = 15
    static let intervalRange: ClosedRange<TimeInterval> = 5...600

    /// Applies a coordinate to the currently selected target.
    var apply: ((CLLocationCoordinate2D) -> Void)?

    var onStateChange: ((State) -> Void)?
    var log: ((String) -> Void)?

    enum State: Equatable {
        case idle
        /// Applied and confirmed by the device at this time.
        case held(Coordinate, confirmedAt: Date)
        /// Applying, or re-applying after a session ended.
        case applying(Coordinate)
        /// The last attempt failed; the device is on its real GPS until one succeeds.
        case failed(Coordinate, reason: String)
    }

    struct Coordinate: Equatable {
        let latitude: Double
        let longitude: Double

        init(_ coordinate: CLLocationCoordinate2D) {
            latitude = coordinate.latitude
            longitude = coordinate.longitude
        }

        var clCoordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        var formatted: String { String(format: "%.6f, %.6f", latitude, longitude) }
    }

    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    var isEnabled: Bool = true {
        didSet {
            guard isEnabled != oldValue else { return }
            restartTimer()
            if isEnabled { reapply(trigger: .manual) }
        }
    }

    var interval: TimeInterval = LocationHoldSupervisor.defaultInterval {
        didSet {
            interval = min(max(interval, Self.intervalRange.lowerBound), Self.intervalRange.upperBound)
            guard interval != oldValue else { return }
            restartTimer()
        }
    }

    private var held: Coordinate?
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    init() {
        // Sleeping the Mac tears down the tunnel and the DVT channel behind it.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reapply(trigger: .systemWake)
        }
    }

    deinit {
        timer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    /// Starts holding `coordinate`, applying it immediately.
    func hold(_ coordinate: CLLocationCoordinate2D) {
        let point = Coordinate(coordinate)
        held = point
        state = .applying(point)

        beginActivity()
        restartTimer()

        log?("Holding \(point.formatted); re-applying every \(Int(interval))s")
        apply?(point.clCoordinate)
    }

    /// Stops holding. The device keeps whatever was last applied until it lapses.
    func release() {
        guard held != nil else { return }
        held = nil
        timer?.invalidate()
        timer = nil
        endActivity()
        state = .idle
        log?("Stopped holding a simulated location")
    }

    /// The device confirmed the point is applied.
    func confirmApplied() {
        guard let held else { return }
        state = .held(held, confirmedAt: Date())
    }

    /// A session ended. The point lapses shortly after, so put it back.
    func sessionEnded(reason: String?) {
        guard let held else { return }

        if let reason {
            log?("Device session failed (\(reason)) — re-applying \(held.formatted)")
            state = .failed(held, reason: reason)
        } else {
            log?("Device session ended — re-applying \(held.formatted)")
            state = .applying(held)
        }

        apply?(held.clCoordinate)
    }

    func reapply(trigger: Trigger) {
        guard let held, isEnabled else { return }

        // Deliberately unconditional. A `simulate-location set` process parks in
        // `wait_return()` and stays alive indefinitely, so "the process is running" is
        // not evidence the device is still honouring the point — which is exactly the
        // case where the location lapsed with nothing in the UI changing. Re-applying
        // costs one short-lived child process; the old session is retired only after
        // the new one is up, so the point is never handed back in between.
        log?("Re-applying \(held.formatted) (\(trigger.rawValue))")
        state = .applying(held)
        apply?(held.clCoordinate)
    }

    // MARK: - Private

    private func restartTimer() {
        timer?.invalidate()
        timer = nil

        guard held != nil, isEnabled else { return }

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.reapply(trigger: .keepAlive)
        }
        timer.tolerance = interval * 0.1
        // `.common` so the timer keeps firing while a menu is open or the map is dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Keeps App Nap and idle sleep from stalling the keep-alive.
    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "Holding a simulated location"
        )
    }

    private func endActivity() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }
}
