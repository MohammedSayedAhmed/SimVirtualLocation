import AppKit
import CoreLocation
import Foundation

/// Keeps a single simulated point applied for as long as the user asked for it.
///
/// A simulated point lives exactly as long as the DVT session that set it. `simulate-location
/// set` gives the point back the moment its process exits, which is why setting once lapses
/// silently — and why re-running it on a timer is worse still: tearing down the old session
/// hands the point back, and the device visibly bounces between the held point and real GPS
/// while the replacement connects.
///
/// So on a real device the hold is a single long-lived `simulate-location play` session over
/// a file of identical points. The channel stays open, the point is never handed back, and
/// this timer only has to notice that the session died and start a new one. Targets with no
/// session to keep open — simulator, Android — are re-applied on the timer instead.
///
/// All members are main-thread only.
final class LocationHoldSupervisor {

    enum Trigger: String {
        case initial = "initial set"
        case keepAlive = "keep-alive"
        case sessionEnded = "session ended"
        case systemWake = "Mac woke from sleep"
        case manual = "manual re-apply"
        case deviceReconnected = "device reconnected"
    }

    static let defaultInterval: TimeInterval = 15
    static let intervalRange: ClosedRange<TimeInterval> = 5...600

    /// Applies a coordinate to the currently selected target.
    var apply: ((CLLocationCoordinate2D) -> Void)?

    /// Whether the session holding the point is still up. When it is, the point is
    /// already applied and replacing it would only hand it back.
    var isSessionAlive: (() -> Bool)?

    /// Whether the target is reachable at all. A helper process outlives the connection
    /// it was using, so "the process is running" says nothing about a device that has
    /// gone away — asking separately is the only way to tell those apart.
    var isTargetAvailable: (() -> Bool)?

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

        /// The point this state is about, if any.
        var coordinate: Coordinate? {
            switch self {
            case .idle:
                return nil
            case .held(let point, _), .applying(let point), .failed(let point, _):
                return point
            }
        }
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
            if isEnabled { reapply(trigger: .keepAlive) }
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

    /// The target went away. The point is kept, but it is no longer in force.
    func targetLost(reason: String) {
        guard let held else { return }
        log?("Target lost (\(reason)) — the held point is no longer applied")
        state = .failed(held, reason: reason)
    }

    /// The target came back. Put the point on again immediately: the session that was
    /// holding it died with the old connection, whatever its process still reports.
    func targetRestored() {
        guard held != nil else { return }
        log?("Target is back — re-applying the held point")
        reapply(trigger: .deviceReconnected)
    }

    func reapply(trigger: Trigger) {
        guard let held, isEnabled else { return }

        // Nothing can be applied to a device that is not there, and nothing about the
        // old session's process proves otherwise — so say so rather than reporting a
        // hold that is not in force.
        if isTargetAvailable?() == false {
            state = .failed(held, reason: "Device disconnected — the point goes back on as soon as it returns.")
            return
        }

        // Replacing a session that is still holding the point is what made the device
        // alternate between the held point and real GPS: tearing the old one down hands
        // the point back, and the replacement needs a second or two to take it again.
        // A live session already *is* the hold, so leave it running.
        if trigger == .keepAlive, isSessionAlive?() == true {
            state = .held(held, confirmedAt: Date())
            return
        }

        log?("Applying \(held.formatted) (\(trigger.rawValue))")
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
