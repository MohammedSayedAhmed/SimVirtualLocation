import AppKit
import CoreLocation
import Foundation

/// Keeps one simulated point applied for as long as the user asked for it, and tells
/// the truth when it cannot.
///
/// Every injection path this app uses is one-shot or session-scoped:
///
/// * the simulator notification is fire-and-forget and is overridden by anything else
///   that sets a location on that simulator;
/// * the developer-disk-image service drops the simulation when its connection closes;
/// * the iOS 17+ DVT channel lives and dies with the `pymobiledevice3` process, and the
///   RSD tunnel behind it goes away whenever the host tunnel is restarted.
///
/// Setting a point once and assuming it sticks is exactly how the location silently
/// reverted to real GPS while the UI still claimed it was on. This supervisor
/// re-asserts the held point on a timer, inspects the outcome of every attempt, and
/// downgrades its status the moment it can no longer confirm the hold.
///
/// All members are main-thread only.
final class LocationHoldSupervisor {

    enum Trigger: String {
        case initialSet = "initial set"
        case keepAlive = "keep-alive"
        case retry = "retry after failure"
        case systemWake = "Mac woke from sleep"
        case appActivated = "app activated"
        case settingsChanged = "settings changed"
        case manual = "manual re-apply"
        case sessionEnded = "device session died"
        case restored = "restored after restart"
    }

    /// Deliberately short. This is the ceiling on how long the device can sit on real
    /// GPS after a silent revert that produced no error to react to.
    static let defaultKeepAliveInterval: TimeInterval = 5
    static let minimumKeepAliveInterval: TimeInterval = 2
    static let maximumKeepAliveInterval: TimeInterval = 300

    /// Consecutive failures tolerated before the hold is declared broken. Below this
    /// the status is amber ("retrying"); at it the status goes red.
    private static let failuresBeforeLost = 3

    /// How often the freshness watchdog looks for a hold that has quietly stopped
    /// being confirmed (a wedged helper, a keep-alive tick that never ran).
    private static let watchdogInterval: TimeInterval = 5

    // MARK: - Collaborators

    /// Applies a coordinate to the currently selected target.
    var inject: (@MainActor (CLLocationCoordinate2D) async -> InjectionOutcome)?

    /// Whether a long-lived helper is still holding a device session open.
    var isSessionAlive: (() -> Bool)?

    /// Why such a session ended by itself, if it did. Reading it clears it.
    var consumeSessionFailureReason: (() -> String?)?

    var onStatusChange: ((LocationHoldStatus) -> Void)?
    var log: ((String) -> Void)?

    // MARK: - State

    private(set) var status: LocationHoldStatus = .idle {
        didSet {
            guard status != oldValue else { return }
            onStatusChange?(status)
        }
    }

    var keepAliveInterval: TimeInterval = LocationHoldSupervisor.defaultKeepAliveInterval {
        didSet {
            keepAliveInterval = min(
                max(keepAliveInterval, LocationHoldSupervisor.minimumKeepAliveInterval),
                LocationHoldSupervisor.maximumKeepAliveInterval
            )
            guard keepAliveInterval != oldValue else { return }
            restartTimers()
        }
    }

    var isKeepAliveEnabled: Bool = true {
        didSet {
            guard isKeepAliveEnabled != oldValue else { return }
            log?(isKeepAliveEnabled
                 ? "Keep-alive enabled — the point will be re-applied every \(Int(keepAliveInterval))s"
                 : "Keep-alive disabled — the location will not be re-applied or verified")
            restartTimers()
            if isKeepAliveEnabled {
                reapplyNow(trigger: .settingsChanged)
            } else if case .hold(let point) = mode {
                // Without a keep-alive nothing can confirm the point is still applied,
                // so it must not keep showing as healthy.
                status = .unverified(coordinate: point, appliedAt: lastConfirmedAt ?? Date())
            }
        }
    }

    private enum Mode: Equatable {
        case idle
        case hold(Coordinate)
        case route
    }

    private var mode: Mode = .idle
    private var lastConfirmedAt: Date?
    private var consecutiveFailures = 0
    private var isInjecting = false
    private var injectionStartedAt: Date?

    private var keepAliveTimer: Timer?
    private var watchdogTimer: Timer?
    private var retryTimer: Timer?

    private var powerAssertion: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var applicationObservers: [NSObjectProtocol] = []

    // MARK: - Lifecycle

    init() {
        observeSystemEvents()
    }

    deinit {
        keepAliveTimer?.invalidate()
        watchdogTimer?.invalidate()
        retryTimer?.invalidate()

        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        applicationObservers.forEach { NotificationCenter.default.removeObserver($0) }

        if let powerAssertion {
            ProcessInfo.processInfo.endActivity(powerAssertion)
        }
    }

    // MARK: - Public

    var heldCoordinate: Coordinate? {
        guard case .hold(let coordinate) = mode else { return nil }
        return coordinate
    }

    /// Starts (or moves) the held point and applies it immediately.
    func hold(_ coordinate: CLLocationCoordinate2D, trigger: Trigger = .initialSet) {
        let point = Coordinate(coordinate)
        let isSamePoint = mode == .hold(point)

        mode = .hold(point)

        if !isSamePoint {
            consecutiveFailures = 0
            lastConfirmedAt = nil
            status = .applying(coordinate: point)
        }

        beginPowerAssertion()
        restartTimers()
        perform(point: point, trigger: trigger)
    }

    /// Switches to route playback: no timer-driven re-assertion, outcomes are reported
    /// by the caller through `record(_:)`.
    func beginRoute() {
        mode = .route
        consecutiveFailures = 0
        lastConfirmedAt = nil
        status = .applying(coordinate: nil)

        beginPowerAssertion()
        restartTimers()
    }

    /// Feeds the outcome of a route step back in, so route playback surfaces failures
    /// the same way a held point does.
    func record(_ outcome: InjectionOutcome) {
        guard case .route = mode else { return }

        if let reason = outcome.failureReason {
            handleFailure(reason: reason, point: nil)
            return
        }

        let now = Date()
        lastConfirmedAt = now
        consecutiveFailures = 0
        status = .route(confirmedAt: now)
    }

    func release(reason: String? = nil) {
        let wasActive = mode != .idle

        mode = .idle
        consecutiveFailures = 0
        lastConfirmedAt = nil

        stopTimers()
        endPowerAssertion()
        status = .idle

        if wasActive {
            log?(reason ?? "Stopped holding the simulated location")
        }
    }

    /// Called the moment a long-lived device session dies on its own.
    ///
    /// This is the difference between a sub-second blip and up to a full keep-alive
    /// interval of real GPS, so it re-applies immediately rather than scheduling.
    func sessionEnded(reason: String) {
        guard case .hold(let point) = mode else { return }

        handleFailure(reason: reason, point: point)

        // `handleFailure` schedules a backed-off retry; a session death is a known,
        // specific event, so go straight at it instead of waiting for that.
        reapplyNow(trigger: .sessionEnded)
    }

    /// Re-applies the held point right now, outside the keep-alive schedule.
    func reapplyNow(trigger: Trigger) {
        guard case .hold(let point) = mode else { return }
        guard !isInjecting else {
            log?("Skipping \(trigger.rawValue) re-apply: an update is already in flight")
            return
        }
        perform(point: point, trigger: trigger)
    }

    // MARK: - Injection

    private func perform(point: Coordinate, trigger: Trigger) {
        guard let inject else { return }

        cancelRetry()
        isInjecting = true
        injectionStartedAt = Date()
        log?("Applying \(point.formatted) (\(trigger.rawValue))")

        Task { @MainActor [weak self] in
            let outcome = await inject(point.clCoordinate)

            guard let self else { return }

            self.isInjecting = false
            self.injectionStartedAt = nil

            // The user may have moved or released the point while this was in flight.
            guard self.mode == .hold(point) else {
                self.log?("Ignoring the result of a superseded location update")
                return
            }

            if let reason = outcome.failureReason {
                self.handleFailure(reason: reason, point: point)
            } else {
                self.confirm(point: point, viaLiveSession: outcome == .holding)
            }
        }
    }

    private func confirm(point: Coordinate, viaLiveSession: Bool) {
        if consecutiveFailures > 0 {
            log?("Location recovered after \(consecutiveFailures) failed attempt(s)")
        }

        let now = Date()
        lastConfirmedAt = now
        consecutiveFailures = 0

        if isKeepAliveEnabled {
            status = .holding(coordinate: point, confirmedAt: now, viaLiveSession: viaLiveSession)
        } else {
            status = .unverified(coordinate: point, appliedAt: now)
        }
    }

    private func handleFailure(reason: String, point: Coordinate?) {
        consecutiveFailures += 1
        log?("Location update failed (\(consecutiveFailures) in a row): \(reason)")

        if consecutiveFailures >= LocationHoldSupervisor.failuresBeforeLost {
            status = .lost(coordinate: point, reason: reason, lastConfirmedAt: lastConfirmedAt)
        } else {
            status = .recovering(
                coordinate: point,
                reason: reason,
                failures: consecutiveFailures,
                lastConfirmedAt: lastConfirmedAt
            )
        }

        scheduleRetry()
    }

    // MARK: - Timers

    private func tick() {
        guard case .hold(let point) = mode else { return }

        // A long-lived session that died since the last tick is the single most
        // common way the location used to vanish without a word.
        if let reason = consumeSessionFailureReason?() {
            handleFailure(reason: reason, point: point)
            return
        }

        if isInjecting {
            let inFlightFor = injectionStartedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
            log?("Keep-alive tick skipped: an update has been in flight for \(inFlightFor)s")
            return
        }

        // A live helper *is* the hold on iOS 17+; re-launching it would only tear
        // down the channel that is currently keeping the point applied.
        if isSessionAlive?() == true {
            confirm(point: point, viaLiveSession: true)
            return
        }

        perform(point: point, trigger: .keepAlive)
    }

    /// Catches a hold that stopped being confirmed without any single attempt failing —
    /// a wedged helper, or keep-alive ticks that stopped running.
    private func checkFreshness() {
        guard case .hold(let point) = mode, isKeepAliveEnabled else { return }
        guard status.severity == .ok, let lastConfirmedAt else { return }

        let age = Date().timeIntervalSince(lastConfirmedAt)
        let limit = max(keepAliveInterval * 2.5, keepAliveInterval + 20)
        guard age > limit else { return }

        handleFailure(
            reason: "No confirmation from the device for \(Int(age))s — the simulated location can no longer be trusted.",
            point: point
        )
    }

    private func restartTimers() {
        stopTimers()

        // Only a held point needs re-assertion; route playback drives its own updates.
        guard case .hold = mode, isKeepAliveEnabled else { return }

        let keepAlive = Timer(timeInterval: keepAliveInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        keepAlive.tolerance = keepAliveInterval * 0.1
        // `.common` so the timer keeps firing while a menu is open or the map is
        // being dragged — modal run-loop modes used to stall it.
        RunLoop.main.add(keepAlive, forMode: .common)
        keepAliveTimer = keepAlive

        let watchdog = Timer(timeInterval: LocationHoldSupervisor.watchdogInterval, repeats: true) { [weak self] _ in
            self?.checkFreshness()
        }
        watchdog.tolerance = 1
        RunLoop.main.add(watchdog, forMode: .common)
        watchdogTimer = watchdog
    }

    private func stopTimers() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        cancelRetry()
    }

    private func scheduleRetry() {
        guard case .hold = mode else { return }
        cancelRetry()

        // Exponential backoff so a transient hiccup recovers within seconds while a
        // permanently broken setup (no pymobiledevice3, no device) settles into a slow
        // poll instead of relaunching a process every couple of seconds forever. The
        // keep-alive tick still runs underneath, so this only ever adds attempts.
        let delay = min(pow(2.0, Double(consecutiveFailures - 1)), 15)

        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.retryTimer = nil
            self.reapplyNow(trigger: .retry)
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private func cancelRetry() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    // MARK: - System integration

    private func observeSystemEvents() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        // Sleeping the Mac tears down USB sessions and RSD tunnels; the point has to
        // be pushed again once it is awake.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            let token = workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reapplyNow(trigger: .systemWake)
            }
            workspaceObservers.append(token)
        }

        let activationToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reapplyNow(trigger: .appActivated)
        }
        applicationObservers.append(activationToken)
    }

    /// Keeps App Nap and idle sleep from throttling or suspending the keep-alive while
    /// a point is being held.
    private func beginPowerAssertion() {
        guard powerAssertion == nil else { return }
        powerAssertion = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "Holding a simulated location"
        )
    }

    private func endPowerAssertion() {
        guard let powerAssertion else { return }
        ProcessInfo.processInfo.endActivity(powerAssertion)
        self.powerAssertion = nil
    }
}
