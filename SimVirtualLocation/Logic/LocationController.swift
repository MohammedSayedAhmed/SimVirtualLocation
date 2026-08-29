//
//  LocationController.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 21.02.2022.
//

import AppKit
import Combine
import CoreLocation
import MapKit

class LocationController: NSObject, ObservableObject, CLLocationManagerDelegate {

    // MARK: - Publishers

    @Published var isSimulating = false
    @Published var speed: Double = 60.0 {
        didSet { scheduleSpeedChange() }
    }
    @Published var pointsMode: PointsMode = .single {
        didSet {
            mapScene.handlePointsModeChange(to: pointsMode)
            if pointsMode == .single {
                clearRouteState()
            }
        }
    }

    @Published var transportType: TransportType = .driving
    /// Simulator or a real device.
    ///
    /// Persisted: this was the only target setting that was not, so every launch began in
    /// simulator mode however the app was actually being used. On a Mac without Xcode
    /// that meant the first location set of every session went to a simulator that does
    /// not exist, and the background scan spent its time shelling out to a missing
    /// `simctl`, until the mode was flipped back by hand.
    @Published var deviceMode: DeviceMode = .simulator {
        didSet {
            guard deviceMode != oldValue else { return }
            defaults.set(deviceMode.rawValue, forKey: AppStorageKey.deviceMode)
            retargetHold()
            Task { @MainActor [weak self] in
                await self?.refreshDevices(silently: true)
            }
        }
    }
    @Published var xcodePath: String = "/Applications/Xcode.app" {
        didSet { defaults.set(xcodePath, forKey: AppStorageKey.xcodePath) }
    }

    @Published var useRSD: Bool = true {
        didSet {
            guard useRSD != oldValue else { return }
            retargetHold()
        }
    }

    /// Establish the iOS 17+ tunnel in-process instead of relying on a tunnel the user starts
    /// with `sudo` in Terminal. Removes the need for RSD Address / RSD Port entirely.
    @Published var useUserspace: Bool = true {
        didSet {
            defaults.set(useUserspace, forKey: AppStorageKey.useUserspace)
            guard useUserspace != oldValue else { return }
            retargetHold()
        }
    }

    /// True while an entire route is being replayed by a single `simulate-location play`
    /// process, in which case `performMovement` animates the map but must not also push
    /// locations itself.
    private var isPlayingRoute = false

    /// Progress of the current device operation, shown next to the device picker.
    @Published var activity: DeviceActivity = .idle

    /// Re-apply a single set point periodically so it cannot lapse back to real GPS.
    @Published var isKeepAliveEnabled: Bool = true {
        didSet {
            guard isKeepAliveEnabled != oldValue else { return }
            defaults.set(isKeepAliveEnabled, forKey: AppStorageKey.keepLocationApplied)
            locationHold.isEnabled = isKeepAliveEnabled
        }
    }

    @Published var keepAliveInterval: Double = LocationHoldSupervisor.defaultInterval {
        didSet {
            guard keepAliveInterval != oldValue else { return }
            defaults.set(keepAliveInterval, forKey: AppStorageKey.keepAliveInterval)
            locationHold.interval = keepAliveInterval
        }
    }

    /// One line describing the held point, or `nil` when nothing is being held.
    @Published private(set) var holdSummary: String?

    /// Whether a point is applied, being applied, or has been lost.
    @Published private(set) var holdState: LocationHoldSupervisor.State = .idle

    // MARK: - Day plan

    @Published var dayPlan = DayPlan() {
        didSet {
            guard dayPlan != oldValue else { return }
            dayPlanStore.save(dayPlan)
        }
    }

    /// The plan resolved against today, once every leg has been routed.
    @Published private(set) var daySchedule: DaySchedule?

    /// What the day plan is doing right now.
    @Published private(set) var dayActivity: DayPlanRunner.Activity = .stopped

    /// Set while the legs are being routed, and after a routing failure.
    @Published private(set) var dayPlanStatus: String?

    var isDayPlanRunning: Bool { dayPlanRunner.isRunning }

    /// True while a simulation is suspended and can be resumed from the same point.
    @Published var isPaused = false

    /// Length of the route currently loaded, in metres. Zero when none is loaded.
    @Published private(set) var routeDistance: CLLocationDistance = 0

    /// Drive like a car rather than a cursor: accelerate, brake into corners, wait at
    /// lights. See `DriveProfile`.
    @Published var isRealisticDriving: Bool = false {
        didSet {
            guard isRealisticDriving != oldValue else { return }
            defaults.set(isRealisticDriving, forKey: AppStorageKey.realisticDriving)
        }
    }

    /// What the routing service thinks the drive takes right now. It already accounts for
    /// the traffic it can see, so a realistic drive stretched to match it reproduces
    /// today's conditions. Zero when no route has been worked out, or when offline —
    /// the drive is then shaped by the model alone.
    @Published private(set) var routeExpectedTravelTime: TimeInterval = 0

    /// Journey time the user wants, in minutes. Applying it derives the speed.
    @Published var targetDurationMinutes: String = ""

    /// Route being played, and how much of it the device has already covered. Used to
    /// rebuild the remainder when the speed changes mid-route.
    /// The route being played, resampled to a fine, even spacing at playback start.
    /// Never rebased mid-route: restarts cut from it, they do not replace it.
    private var playbackCoordinates: [CLLocationCoordinate2D] = []

    /// The last point the device reported playing. Restarting from here is exact
    /// whatever the GPX's own point density was — an index into the route is not,
    /// because the played file has a different number of points than the route.
    private var playbackPosition: CLLocationCoordinate2D?

    /// The seed and traffic estimate the route started with, so a mid-route restart
    /// keeps the same lights and the same share of the same estimate.
    private var playbackSeed: UInt64 = 1
    private var playbackEstimate: TimeInterval = 0
    private var speedChangeWork: DispatchWorkItem?

    /// How often connected devices are rescanned. Scanning shells out to pymobiledevice3,
    /// so poll briskly only while waiting for a device to appear and back off once one is
    /// attached, where the scan exists just to notice a disconnect.
    private static let deviceScanIntervalWaiting: TimeInterval = 3
    private static let deviceScanIntervalAttached: TimeInterval = 15

    private var deviceMonitorTask: Task<Void, Never>?

    @Published var bootedSimulators: [Simulator] = []
    @Published var selectedSimulator: String = ""

    @Published var connectedDevices: [Device] = []
    @Published var selectedDevice: String = ""

    @Published var showingAlert: Bool = false
    @Published var platform: AppPlatform = .iOS {
        didSet {
            defaults.set(platform.rawValue, forKey: AppStorageKey.platform)
            guard platform != oldValue else { return }
            retargetHold()
        }
    }
    @Published var adbPath: String = ""
    @Published var adbDeviceId: String = ""
    @Published var isEmulator: Bool = false

    @Published var rsdAddress: String = ""
    @Published var rsdPort: String = ""

    @Published var timeScale: Double = 1.5 {
        didSet { runner.timeDelay = timeScale }
    }

    @Published var logs: [LogEntry] = []
    @Published var showLogs: Bool = false

    let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    // MARK: - Internal (previews & tests)

    var alertText: String = ""

    // MARK: - Private

    private let mapView: MapView
    private let mapScene: MapSceneCoordinator
    private let runner: DeviceLocationRunning
    private let locationHold = LocationHoldSupervisor()
    private let dayPlanRunner = DayPlanRunner()
    private let dayPlanStore = DayPlanStore()
    private let savedLocationsStore: SavedLocationsStore
    private let locationManager = CLLocationManager()
    private let defaults: UserDefaults = UserDefaults.standard
    private let iOSDeveloperImagePath = "/Contents/Developer/Platforms/iPhoneOS.platform/DeviceSupport/"
    private let iOSDeveloperImageDmg = "/DeveloperDiskImage.dmg"
    private let iOSDeveloperImageSignature = "/DeveloperDiskImage.dmg.signature"

    private var isMapCentered = false

    private var tracks: [Track] = []
    private var currentTrackIndex: Int = 0
    private var lastTrackLocation: CLLocationCoordinate2D?
    private var tracksTimes: [Track: Double] = [:]

    private var timer: Timer?
    private var wasHoldLost = false

    /// The last CoreLocation failure text, so an error it retries forever is logged once.
    private var lastLocationManagerError: String?

    /// How many times the newest log line has repeated, so a failure on a timer collapses.
    private var repeatedLogCount = 0

    @Published var savedLocations: [Location] = []

    // MARK: - Init

    init(
        mapView: MapView,
        runner: DeviceLocationRunning = Runner(),
        savedLocationsStore: SavedLocationsStore = SavedLocationsStore()
    ) {
        self.mapView = mapView
        self.mapScene = MapSceneCoordinator(mapView: mapView.mkMapView)
        self.runner = runner
        self.savedLocationsStore = savedLocationsStore
        super.init()

        if defaults.object(forKey: AppStorageKey.useUserspace) != nil {
            useUserspace = defaults.bool(forKey: AppStorageKey.useUserspace)
        }

        runner.onLocationPlayed = { [weak self] latitude, longitude in
            DispatchQueue.main.async {
                guard let self = self else { return }

                // A stationary hold is played the same way a route is, so every point
                // `play` reports is the device confirming the held point is still on.
                guard self.isPlayingRoute else {
                    self.locationHold.confirmApplied()
                    return
                }

                let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                self.playbackPosition = coordinate
                self.mapScene.removeSimulationAnnotationFromMap()
                self.mapScene.placeSimulationAnnotation(at: coordinate)
            }
        }

        runner.onActivity = { [weak self] activity in
            DispatchQueue.main.async {
                self?.activity = activity
            }
        }

        runner.onLocationConfirmed = { [weak self] in
            DispatchQueue.main.async {
                self?.locationHold.confirmApplied()
            }
        }

        // A `set` session ending means the device has given the point back. Only the
        // simulator/Android paths use `set` now, but the signal still matters there.
        // The play process exiting on its own is the route ending. With that session
        // gone the device is about to revert to real GPS, which is never allowed to
        // pass silently — so the end of a route immediately becomes a held point.
        runner.onPlaybackFinished = { [weak self] succeeded in
            DispatchQueue.main.async {
                self?.handleRoutePlaybackFinished(succeeded: succeeded)
            }
        }

        runner.onSessionEnded = { [weak self] reason in
            DispatchQueue.main.async {
                guard let self, !self.usesPlaybackHold else { return }
                self.locationHold.sessionEnded(reason: reason)
            }
        }

        configureLocationHold()

        // Stored settings are read here, synchronously, because everything below depends
        // on knowing what the target is. They used to be restored inside the Task below,
        // behind an `await refreshDevices()`, while the held point was restored on the
        // next runloop turn — so the point went back on before the app knew whether it
        // was pointed at a simulator or a phone, and a device hold resumed down the
        // simulator path with the phone left on real GPS under a UI saying "Holding".
        if let storedPlatform = AppPlatform(rawValue: defaults.integer(forKey: AppStorageKey.platform)) {
            platform = storedPlatform
        }
        if let storedDeviceMode = DeviceMode(rawValue: defaults.integer(forKey: AppStorageKey.deviceMode)) {
            deviceMode = storedDeviceMode
        }
        adbPath = defaults.string(forKey: AppStorageKey.adbPath) ?? ""
        adbDeviceId = defaults.string(forKey: AppStorageKey.adbDeviceId) ?? ""
        isEmulator = defaults.bool(forKey: AppStorageKey.isEmulator)
        xcodePath = defaults.string(forKey: AppStorageKey.xcodePath) ?? "/Applications/Xcode.app"
        savedLocations = savedLocationsStore.load()

        runner.log = { [weak self] message in
            DispatchQueue.main.async {
                self?.log(message)
            }
        }

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
        // One fix, not a continuous stream. The Mac's own position is wanted twice —
        // to centre the map at launch and when "My Mac" is pressed — and leaving updates
        // running meant CoreLocation retried indefinitely, logging a failure every few
        // minutes for the entire time the app was open.
        locationManager.requestLocation()

        mapView.viewHolder.clickAction = { [weak self] gesture in
            guard let self else { return }
            self.mapScene.handleMapClick(gesture, pointsMode: self.pointsMode)
        }

        // @MainActor because everything below it is `@Published`: settling the stored
        // settings at launch was writing them from whatever thread this Task landed on.
        Task { @MainActor in
            await refreshDevices()
            startDeviceMonitoring()

            // Only now: the target settings are already in place from init, and the
            // device list is known, so a resumed hold goes to the right place.
            restoreHeldPointIfNeeded()
            resumeDayPlanIfNeeded()
        }
    }

    // MARK: - Public

    func refreshDevices() async {
        await refreshDevices(silently: false)
    }

    /// - Parameter silently: when true this is a background rescan, so a failure is logged
    ///   rather than raised — a device being unplugged is not an error worth alarming about.
    ///
    /// Split deliberately in two. Both discovery calls shell out and block whatever thread
    /// they are on, so they must not run on the main one; everything they produce is then
    /// applied on the main thread, because publishing a change from here is what froze the
    /// whole window. See `applyDiscovery` for why.
    func refreshDevices(silently: Bool) async {
        // Only look for simulators when one is the target. Otherwise every rescan shelled
        // out to `simctl` and logged its failure, which on a Mac without the simulator
        // tools installed filled the log with an error nobody can act on.
        let wantsSimulators = await MainActor.run { platform == .iOS && deviceMode == .simulator }

        // A background rescan runs every few seconds forever, and logging the command
        // and its result each time was most of what ever reached the log. Failures still
        // log every time — those are the lines someone is looking for.
        let verbose = !silently

        var simulators: [Simulator]?
        if wantsSimulators {
            simulators = (try? SimulatorDiscovery.fetchBootedSimulators(
                verbose: verbose,
                log: { [weak self] in self?.log($0) }
            )) ?? []
        }

        let devices: [Device]?
        do {
            devices = try await IOSUSBDeviceDiscovery.fetchConnectedDevices(
                runner: runner,
                verbose: verbose,
                showAlert: { [weak self] in self?.showAlert($0) },
                log: { [weak self] in self?.log($0) }
            )
        } catch {
            devices = nil
        }

        await applyDiscovery(simulators: simulators, devices: devices, silently: silently)
    }

    /// Applies what a rescan found, on the main thread.
    ///
    /// This used to run wherever the rescan happened, which was a background thread, and
    /// it both wrote `@Published` properties and called into `locationHold` and
    /// `dayPlanRunner` — two objects whose members are main-thread only and whose timers
    /// belong to the main run loop.
    ///
    /// The `@Published` writes were the worse half. SwiftUI holds a lock while it
    /// publishes, and a background write can end up holding that lock while it waits for
    /// the main thread, at the same moment the main thread is waiting for the lock. Both
    /// stop, the window freezes, and nothing is logged because the log is published too.
    /// Unplugging a device and plugging it back in ran this whole function, which is why
    /// that was the way to hit it.
    @MainActor
    private func applyDiscovery(simulators: [Simulator]?, devices: [Device]?, silently: Bool) {
        // Assigning a @Published property publishes whether or not the value changed, and
        // this runs on a timer forever, so an unchanged rescan was redrawing the window
        // several times a minute for nothing. Each assignment is guarded separately: the
        // selection fixups below still have to run even when the list itself is the same.
        if let simulators {
            if simulators != bootedSimulators {
                bootedSimulators = simulators
            }
            if selectedSimulator.isEmpty || !simulators.contains(where: { $0.id == selectedSimulator }) {
                let replacement = simulators.first?.id ?? ""
                if replacement != selectedSimulator {
                    selectedSimulator = replacement
                }
            }
        }

        let previousSelection = selectedDevice
        let previousDevices = connectedDevices

        if let devices {
            if devices != connectedDevices {
                connectedDevices = devices
            }
        } else {
            if !connectedDevices.isEmpty {
                connectedDevices = []
            }
            if !silently {
                activity = .failed("Could not list devices — see Logs")
            }
        }

        // Keep the user's choice as long as that device is still attached.
        let newSelection = connectedDevices.contains(where: { $0.id == previousSelection })
            ? previousSelection
            : (connectedDevices.first?.id ?? "")
        if newSelection != selectedDevice {
            selectedDevice = newSelection
        }

        let changed = connectedDevices != previousDevices

        if connectedDevices.isEmpty {
            if changed, !previousDevices.isEmpty {
                handleDeviceDisconnected()
            } else if activity == .idle {
                activity = .working("Waiting for a device…")
            }
            return
        }

        guard changed else { return }

        if previousDevices.isEmpty {
            activity = .active("Device connected")
            // Waiting for the next keep-alive tick meant over a minute on real GPS after
            // the cable came back, because the dead session still looked alive.
            locationHold.targetRestored()
            // A leg in progress was being played by a session that died with the cable,
            // and unlike a held point nothing else would notice.
            dayPlanRunner.resume()
            // Nor did a route. A held point came back by itself and a day plan came back
            // by itself, but a route stayed paused for as long as the app was left open,
            // with the device on its real GPS the whole time.
            resumeRouteAfterReconnect()
        } else {
            activity = .idle
        }
        log("connected devices: \(connectedDevices.map { $0.name }.joined(separator: ", "))")
    }

    /// The device went away mid-session.
    ///
    /// iOS drops the simulated location as soon as the tunnel dies, so the phone is already
    /// back on real GPS. Say so rather than leaving a stale "Location set" on screen, and
    /// suspend any route instead of resuming it silently — re-spoofing a location the user
    /// is no longer watching is worse than making them press Resume.
    private func handleDeviceDisconnected() {
        log("device disconnected")

        // The helper process keeps running against a connection that no longer exists,
        // so the hold has to be told directly — it cannot infer this from the process.
        locationHold.targetLost(reason: "Device disconnected — the point goes back on as soon as it returns.")

        guard isSimulating else {
            activity = .failed("Device disconnected — location no longer simulated")
            return
        }

        runner.stopRoutePlayback()
        timer?.invalidate()
        timer = nil
        isPaused = true
        activity = .failed("Device disconnected — simulation paused")

        // A lost hold beeps and asks for attention because nobody is watching the Mac
        // while a location is being held. A route losing its device leaves the phone on
        // real GPS just the same, and said so only in a panel nobody was looking at.
        announceLoss()
    }

    /// Rescan for devices on a timer so connecting a phone is noticed without the user
    /// having to ask. Cancelled and restarted rather than left to stack up.
    private func startDeviceMonitoring() {
        deviceMonitorTask?.cancel()
        deviceMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }

                let interval = await MainActor.run {
                    self.connectedDevices.isEmpty
                        ? Self.deviceScanIntervalWaiting
                        : Self.deviceScanIntervalAttached
                }

                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }

                await self.refreshDevices(silently: true)
            }
        }
    }

    func setCurrentLocation() {
        guard let location = locationManager.location?.coordinate else {
            // Nothing cached: ask for one now rather than reporting failure. Updates are
            // not left running, so the last fix can be older than CoreLocation keeps.
            log("no Mac location cached — asking CoreLocation for one")
            locationManager.requestLocation()
            showAlert("Working out where this Mac is — try again in a moment.")
            return
        }
        holdLocation(location)
    }

    func setSelectedLocation(toBPoint: Bool = false) {
        let endpoints = mapScene.annotationEndpoints()
        if toBPoint {
            guard endpoints.count == 2 else {
                showAlert("Point B is not selected")
                return
            }
            holdLocation(endpoints[1].coordinate)
        } else {
            guard let annotation = endpoints.first else {
                showAlert("Point A is not selected")
                return
            }
            holdLocation(annotation.coordinate)
        }
    }

    func makeRoute() {
        mapScene.makeRoute(
            transportType: transportType,
            showAlert: showAlert,
            onRouteReady: { [weak self] route in
                self?.routeDistance = route.distance
                self?.routeExpectedTravelTime = route.expectedTravelTime
            }
        )
    }

    /// Forget everything derived from a route once that route is gone, so distance,
    /// journey time and the duration control do not outlive what they describe.
    private func clearRouteState() {
        routeDistance = 0
        routeExpectedTravelTime = 0
        targetDurationMinutes = ""
        tracks = []
        tracksTimes = [:]
        playbackCoordinates = []
        playbackPosition = nil
        playbackSeed = 1
        playbackEstimate = 0
    }

    /// Distance and journey time for the loaded route at the current speed.
    /// Whether playback will actually drive realistically. The toggle only changes the
    /// GPX that `play` walks, and only a physical iOS device is driven that way —
    /// simulator and Android move on the constant-speed timer regardless, so promising
    /// them traffic and lights would be describing a drive that will not happen.
    var usesRealisticPlayback: Bool {
        isRealisticDriving && platform == .iOS && deviceMode == .device
    }

    var routeSummary: String? {
        guard routeDistance > 0 else { return nil }

        // A realistic drive takes as long as the routing estimate says, because that is
        // what it is fitted to. Quoting the constant-speed figure there would be wrong.
        let usesEstimate = usesRealisticPlayback && routeExpectedTravelTime > 0
        let seconds = usesEstimate
            ? routeExpectedTravelTime
            : routeDistance / max(speed / 3.6, 0.1)

        let minutes = Int((seconds / 60).rounded())
        let duration = minutes >= 60
            ? "\(minutes / 60)h \(minutes % 60)m"
            : "\(max(minutes, 1)) min"

        let distance = String(format: "%.2f km", routeDistance / 1000)

        if usesEstimate {
            let average = routeDistance / max(routeExpectedTravelTime, 1) * 3.6
            return "\(distance) · \(duration) with current traffic · averages \(Int(average.rounded())) km/h"
        }
        if usesRealisticPlayback {
            return "\(distance) · about \(duration) · no traffic estimate, driving modelled"
        }
        return "\(distance) · about \(duration) at \(Int(speed.rounded())) km/h"
    }

    /// Pick the speed that covers the loaded route in `targetDurationMinutes`.
    ///
    /// Speed is clamped to the slider's range, and the user is told when the requested
    /// time is not achievable within it rather than being given a silently wrong speed.
    func applyTargetDuration() {
        guard routeDistance > 0 else {
            showAlert("Make a route first, then set how long it should take.")
            return
        }

        guard let minutes = Double(targetDurationMinutes.trimmingCharacters(in: .whitespaces)),
              minutes > 0 else {
            showAlert("Enter the journey time in minutes, for example 20.")
            return
        }

        let required = routeDistance / (minutes * 60) * 3.6
        let clamped = min(max(required, Self.minimumSpeed), Self.maximumSpeed)
        speed = (clamped / 5).rounded() * 5

        if required > Self.maximumSpeed || required < Self.minimumSpeed {
            showAlert(
                String(
                    format: "That journey needs %.0f km/h, outside the %.0f–%.0f range. Speed set to %.0f km/h.",
                    required, Self.minimumSpeed, Self.maximumSpeed, speed
                )
            )
        }

        log("target duration \(Int(minutes)) min over \(String(format: "%.2f", routeDistance / 1000)) km — speed set to \(Int(speed)) km/h")
    }

    static let minimumSpeed: Double = 5
    static let maximumSpeed: Double = 200

    func simulateRoute() {
        guard let route = mapScene.route else {
            showAlert("No route for simulation")
            return
        }

        stopSimulation()

        tracks = []
        tracksTimes = [:]

        let buffer = UnsafeBufferPointer(start: route.polyline.points(), count: route.polyline.pointCount)

        for i in 0..<route.polyline.pointCount {
            let trackStartPoint = buffer[i]
            var trackEndPoint: MKMapPoint?
            if i + 1 < route.polyline.pointCount {
                trackEndPoint = buffer[i + 1]
            }

            if let trackEndPoint = trackEndPoint {
                tracks.append(Track(startPoint: trackStartPoint, endPoint: trackEndPoint))
            }
        }

        log("Route segment distances: \(tracks.map { CLLocation.distance(from: $0.startPoint.coordinate, to: $0.endPoint.coordinate) })")

        // The estimate belongs to the route on the map, so read it from there at the
        // moment of starting: a straight A-to-B run in between zeroes the published
        // copy, and simulating the road route again would otherwise run modelled-only.
        routeDistance = route.distance
        routeExpectedTravelTime = route.expectedTravelTime

        isPaused = false
        invalidateState()
        isPlayingRoute = startRoutePlayback()

        startMovementTimer()
    }

    func simulateFromAToB() {
        let endpoints = mapScene.annotationEndpoints()
        guard endpoints.count == 2 else {
            showAlert("Route requires two points")
            return
        }

        stopSimulation()
        tracksTimes = [:]
        tracks = [
            Track(
                startPoint: MKMapPoint(endpoints[0].coordinate),
                endPoint: MKMapPoint(endpoints[1].coordinate)
            )
        ]

        // A straight A-to-B run has no MKRoute, so measure the leg directly — and it has
        // no traffic estimate either. A stale one from an earlier road route would
        // otherwise stretch this run to fit a journey it has nothing to do with.
        routeDistance = CLLocation.distance(from: endpoints[0].coordinate, to: endpoints[1].coordinate)
        routeExpectedTravelTime = 0

        isPaused = false
        invalidateState()
        isPlayingRoute = startRoutePlayback()

        startMovementTimer()
    }

    func updateMapRegion(force: Bool = false) {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
            return
        }

        guard !isMapCentered || force, let location = locationManager.location else {
            locationManager.requestAlwaysAuthorization()
            return
        }

        isMapCentered = true

        mapView.mkMapView.showsUserLocation = true

        let viewRegion = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000)
        let adjustedRegion = mapView.mkMapView.regionThatFits(viewRegion)

        mapView.mkMapView.setRegion(adjustedRegion, animated: true)

        mapView.mkMapView.showsUserLocation = true
    }

    func prepareEmulator() {
        if adbDeviceId.isEmpty {
            showAlert("Please specify device id")
            return
        }

        if adbPath.isEmpty {
            showAlert("Please specify path to adb")
            return
        }

        executeAdbCommand(args: ["shell", "settings", "put", "secure", "location_providers_allowed", "+gps"])
        executeAdbCommand(
            args: ["shell", "settings", "put", "secure", "location_providers_allowed", "+network"],
            successMessage: "Emulator is ready"
        )
    }

    func installHelperApp() {
        if adbDeviceId.isEmpty {
            showAlert("Please specify device id")
            return
        }

        if adbPath.isEmpty {
            showAlert("Please specify path to adb")
            return
        }

        guard let apkURL = Bundle.main.url(forResource: "helper-app", withExtension: "apk") else {
            showAlert("The helper APK is missing from the app bundle.")
            return
        }

        let args = ["-s", adbDeviceId, "install", apkURL.path]

        executeAdbCommand(
            args: args,
            successMessage: "Helper app successfully installed. Please open MockLocationForDeveloper app on your phone and grant all required permissions"
        )
    }

    func stopSimulation() {
        isSimulating = false
        isPlayingRoute = false
        isPaused = false
        persistHeldPoint(nil)
        locationHold.release()
        runner.stop()
    }

    /// Suspend or resume the running simulation without losing progress.
    func togglePauseSimulation() {
        guard isSimulating else { return }

        if isPaused {
            if isPlayingRoute {
                if runner.isPlaybackRunning {
                    runner.resumeRoutePlayback()
                } else {
                    // Playback died with the connection; replay what is left of the route.
                    restartPlaybackFromCurrentPosition()
                }
            }
            isPaused = false
            startMovementTimer()
            log("simulation resumed")
        } else {
            if isPlayingRoute { runner.pauseRoutePlayback() }
            isPaused = true
            timer?.invalidate()
            timer = nil
            log("simulation paused")
        }
    }

    /// Apply a speed change to a route already in flight.
    ///
    /// The GPX encodes speed as the gap between timestamps, so the only way to change it is
    /// to rewrite the remainder of the route and restart playback from where the device
    /// actually is. Debounced, because dragging the slider emits continuously.
    private func scheduleSpeedChange() {
        speedChangeWork?.cancel()
        guard isSimulating, isPlayingRoute, !isPaused else { return }

        let work = DispatchWorkItem { [weak self] in
            self?.restartPlaybackFromCurrentPosition()
        }
        speedChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func restartPlaybackFromCurrentPosition() {
        guard isSimulating, isPlayingRoute else { return }
        guard !connectedDevices.isEmpty else {
            activity = .failed("No device connected")
            return
        }

        guard playbackCoordinates.count > 1 else { return }

        // Cut at the point the device last reported, not at a counted index: the GPX
        // holds a different number of points than the route (denser when realistic,
        // speed-dependent when not), so an index into one means nothing in the other.
        let cut = playbackPosition.map { Polyline.nearestVertex(to: $0, in: playbackCoordinates) } ?? 0
        let remaining = Array(playbackCoordinates[cut...])
        guard remaining.count > 1 else { return }

        runner.stopRoutePlayback()

        do {
            // The remainder gets the remaining share of the estimate the route STARTED
            // with, measured against the whole route — playbackCoordinates is never
            // rebased, so a second restart still shares out the same whole.
            let cumulative = Polyline.cumulativeDistances(playbackCoordinates)
            let total = cumulative.last ?? 0
            let fraction = total > 0 ? 1 - (cumulative[cut] / total) : 1.0

            let url = try writeDriveGPX(
                coordinates: remaining,
                speedKph: speed,
                expectedTravelTime: playbackEstimate,
                fraction: fraction,
                seed: playbackSeed
            )
            let connection = iosConnection

            Task {
                try await runner.playRoute(gpxURL: url, connection: connection, activityLabel: "Route playing", showAlert: showAlert)
            }

            let km = (total - cumulative[cut]) / 1000
            log("speed changed to \(Int(speed)) km/h — replaying the remaining \(String(format: "%.1f", km)) km")
        } catch {
            showAlert(error.localizedDescription)
        }
    }

    private func startMovementTimer() {
        // Device playback needs no timer: the play session paces the route, the device
        // reports each point it applies, and those reports drive the map. Running the
        // constant-speed walk alongside it put two authors on one pin — the timer
        // marched ahead at slider speed while the realistic drive braked and waited,
        // and the pin snapped between the two several times a minute. The timer's
        // other job, noticing the route has ended, is the play process exiting.
        guard !isPlayingRoute else { return }

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: timeScale, repeats: true) { [weak self] _ in
            self?.performMovement()
        }
    }

    func reset() {
        mapScene.resetMapVisuals()
        clearRouteState()
        persistHeldPoint(nil)
        locationHold.release()

        if platform == .iOS {
            runner.resetIos(showAlert: showAlert)
        } else {
            runner.resetAndroid(adbDeviceId: adbDeviceId, adbPath: adbPath, showAlert: showAlert)
        }
    }

    func mountDeveloperImage() {
        guard let device = connectedDevices.first(where: { $0.id == selectedDevice }) else {
            showAlert("No selected device")
            return
        }

        Task {
            do {
                let task = try await runner.taskForIOS(
                    args: [
                        "mounter",
                        "mount-developer",
                        "--udid",
                        device.id,
                        makeDeveloperImageDmgPath(iOSVersion: device.version),
                        makeDeveloperImageSignaturePath(iOSVersion: device.version)
                    ],
                    showAlert: showAlert
                )
                let result = try ProcessRunner.run(task)
                Self.presentPymobileDeviceOutput(stdout: result.stdout, stderr: result.stderr, showAlert: showAlert)
            } catch {
                showAlert(error.localizedDescription)
            }
        }
    }

    func unmountDeveloperImage() {
        Task {
            do {
                let task = try await runner.taskForIOS(
                    args: [
                        "mounter",
                        "umount-developer"
                    ],
                    showAlert: showAlert
                )
                let result = try ProcessRunner.run(task)
                Self.presentPymobileDeviceOutput(stdout: result.stdout, stderr: result.stderr, showAlert: showAlert)
            } catch {
                showAlert(error.localizedDescription)
            }
        }
    }

    func savePointA() {
        guard let point = mapScene.annotationEndpoints().first?.coordinate else {
            showAlert("Point A is not selected")
            return
        }

        savedLocations.append(
            Location(
                name: "Point A (\(point.latitude) - \(point.longitude))",
                latitude: point.latitude,
                longitude: point.longitude
            )
        )

        persistSavedLocations()
    }

    func savePointB() {
        let endpoints = mapScene.annotationEndpoints()
        guard endpoints.count == 2, let point = endpoints.last?.coordinate else {
            showAlert("Point B is not selected")
            return
        }

        savedLocations.append(
            Location(
                name: "Point B (\(point.latitude) - \(point.longitude))",
                latitude: point.latitude,
                longitude: point.longitude
            )
        )

        persistSavedLocations()
    }

    func removeLocation(location: Location) {
        savedLocations.removeAll { $0.id == location.id }
        persistSavedLocations()
    }

    func update(_ location: Location, with name: String) {
        guard let locationIndex = savedLocations.firstIndex(where: { $0.id == location.id }) else {
            return
        }

        savedLocations.remove(at: locationIndex)
        savedLocations.insert(
            Location(
                name: name,
                latitude: location.latitude,
                longitude: location.longitude
            ),
            at: locationIndex
        )

        persistSavedLocations()
    }

    func putLocationOnMap(location: Location) {
        mapScene.addLocation(
            coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude),
            pointsMode: pointsMode
        )
    }

    /// Puts a message in front of the user.
    ///
    /// This used to stop any running simulation as a side effect, which was invisible
    /// from the call sites: it is handed to device discovery and to every spawned
    /// process, so a background rescan or a stray line on a helper's stderr could end a
    /// drive that was going perfectly well. Callers that mean to stop now say so.
    func showAlert(_ text: String) {
        DispatchQueue.main.async {
            self.alertText = text
            self.showingAlert = true
            self.log("Alert: \(text)")
        }
    }

    func importLocations(from data: Data) {
        let locations = (try? JSONDecoder().decode([Location].self, from: data)) ?? []

        savedLocations.append(contentsOf: locations)
        persistSavedLocations()
    }

    func setToCoordinate(latString: String = "", lngString: String = "") {
        let lat = Double(latString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .nan
        let lng = Double(lngString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .nan

        guard CoordinateParsing.isValid(latitude: lat, longitude: lng) else {
            showAlert("Invalid coordinates (latitude −90…90, longitude −180…180)")
            return
        }

        putLocationOnMap(location: Location(name: "", latitude: lat, longitude: lng))
        holdLocation(CLLocationCoordinate2D(latitude: lat, longitude: lng))
    }

    func setToCoordinate(latLngString: String = "") {
        let splitValue = latLngString.components(separatedBy: ",")

        guard latLngString.contains(","), splitValue.count == 2 else {
            showAlert("Use the format latitude, longitude (comma-separated)")
            return
        }

        let latSplitString = splitValue[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let lngSplitString = splitValue[1].trimmingCharacters(in: .whitespacesAndNewlines)

        setToCoordinate(latString: latSplitString, lngString: lngSplitString)
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        updateMapRegion()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updateMapRegion()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // This is the Mac's own position failing, not the device's, and CoreLocation
        // retries on its own. Saying so once is useful; saying so every few minutes for
        // hours pushed everything else out of a capped log.
        let description = error.localizedDescription
        guard description != lastLocationManagerError else { return }
        lastLocationManagerError = description
        log("Mac's own location is unavailable: \(description)")
    }

    // MARK: - Private

    private func persistSavedLocations() {
        savedLocationsStore.save(savedLocations)
    }

    private func invalidateState() {
        timer?.invalidate()
        timer = nil
        isSimulating = true
        lastTrackLocation = nil
        currentTrackIndex = 0
    }

    /// How the iOS 17+ device should be reached.
    private var iosConnection: IOSConnection {
        useUserspace ? .userspace(udid: selectedDevice) : .rsd(address: rsdAddress, port: rsdPort)
    }

    /// Coordinates along the computed route, in order.
    private func routeCoordinates() -> [CLLocationCoordinate2D] {
        guard let last = tracks.last else { return [] }
        return tracks.map { $0.startPoint.coordinate } + [last.endPoint.coordinate]
    }

    /// Hand the whole route to the device as one `simulate-location play` process.
    ///
    /// - Returns: `true` when playback started, meaning `performMovement` should only animate
    ///   the map rather than pushing a location per waypoint.
    private func startRoutePlayback() -> Bool {
        guard platform == .iOS, deviceMode == .device else { return false }

        let coordinates = routeCoordinates()
        guard coordinates.count > 1 else { return false }

        // Ten-metre spacing, so "the vertex nearest the played position" is within ten
        // metres of the truth. Raw route polylines put a whole straight between vertices.
        playbackCoordinates = Polyline.resample(coordinates, step: 10)
        playbackPosition = nil
        playbackSeed = Self.driveSeed(for: coordinates)
        playbackEstimate = routeExpectedTravelTime

        do {
            let url = try writeDriveGPX(
                coordinates: coordinates,
                speedKph: speed,
                expectedTravelTime: playbackEstimate,
                seed: playbackSeed
            )
            let connection = iosConnection

            Task {
                try await runner.playRoute(gpxURL: url, connection: connection, activityLabel: "Route playing", showAlert: showAlert)
            }

            // The count is the route's own points, not the drive's — a realistic drive
            // writes many times more — and the session is still only being asked for
            // here, since the tunnel takes seconds to come up. Say what is true.
            log("starting the drive — connecting to the device")
            return true
        } catch {
            showAlert(error.localizedDescription)
            return false
        }
    }

    private func performMovement() {
        // Playback owns the pin; see startMovementTimer.
        guard !isPlayingRoute else { return }

        guard isSimulating, tracks.count > 0, currentTrackIndex < tracks.count else {
            isSimulating = false
            isPaused = false
            timer?.invalidate()
            timer = nil
            currentTrackIndex = 0
            printTimesToLog()
            return
        }

        let track = tracks[currentTrackIndex]
        let trackMove = track.getNextLocation(
            from: lastTrackLocation,
            speed: (speed / 3.6) * timeScale
        )

        mapScene.removeSimulationAnnotationFromMap()

        switch trackMove {
        case .moveTo(to: let to, from: let from, withSpeed: let moveSpeed):
            lastTrackLocation = to
            if !isPlayingRoute { run(location: to) }
            mapScene.placeSimulationAnnotation(at: to)
            log("move to — distance=\(CLLocation.distance(from: from, to: to)), speed=\(moveSpeed)")

        case .finishTo(to: let to, from: let from, withSpeed: let moveSpeed):
            lastTrackLocation = nil
            currentTrackIndex += 1
            if !isPlayingRoute { run(location: to) }
            mapScene.placeSimulationAnnotation(at: to)
            log("finish to — distance=\(CLLocation.distance(from: from, to: to)), speed=\(moveSpeed)")
        }

        tracksTimes[track] = (tracksTimes[track] ?? 0) + timeScale
    }

    private func executeAdbCommand(args: [String], successMessage: String? = nil) {
        if adbDeviceId.isEmpty {
            showAlert("Please specify device id")
            return
        }

        if adbPath.isEmpty {
            showAlert("Please specify path to adb")
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: adbPath)
        task.arguments = args

        let errorPipe = Pipe()

        task.standardError = errorPipe

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            showAlert(error.localizedDescription)
            return
        }

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errorData, as: UTF8.self)

        if !errorText.isEmpty {
            showAlert(errorText)
        } else if let successMessage = successMessage {
            showAlert(successMessage)
        }
    }

    private func printTimesToLog() {
        tracksTimes.forEach { track, time in
            let distance = CLLocation.distance(from: track.startPoint.coordinate, to: track.endPoint.coordinate)
            let avgSpeed = distance / time
            log("Track result: speed=\(avgSpeed * 3.6) km/h, distance=\(distance), time=\(time)")
        }
    }

    private func configureLocationHold() {
        isKeepAliveEnabled = defaults.object(forKey: AppStorageKey.keepLocationApplied) as? Bool ?? true
        isRealisticDriving = defaults.bool(forKey: AppStorageKey.realisticDriving)

        let storedInterval = defaults.double(forKey: AppStorageKey.keepAliveInterval)
        keepAliveInterval = storedInterval > 0 ? storedInterval : LocationHoldSupervisor.defaultInterval

        locationHold.isEnabled = isKeepAliveEnabled
        locationHold.interval = keepAliveInterval

        locationHold.apply = { [weak self] coordinate in
            self?.applyHeldLocation(coordinate)
        }

        // The timer only has to restart a session that has ended. A session that is
        // still up already holds the point, and replacing it is what made the device
        // ping-pong between the held point and real GPS.
        locationHold.isSessionAlive = { [weak self] in
            guard let self, self.usesPlaybackHold else { return false }
            return self.runner.isPlaybackRunning
        }

        // Whether there is anything to apply a point to at all. This used to answer
        // "yes" for every target that is not a play session, so a hold aimed at a
        // simulator that was not running re-applied and re-alerted on every tick
        // forever, and reported itself as held in between.
        locationHold.isTargetAvailable = { [weak self] in
            guard let self else { return false }
            if self.platform == .android {
                return !self.adbDeviceId.isEmpty && !self.adbPath.isEmpty
            }
            if self.deviceMode == .simulator {
                return self.bootedSimulators.contains { !$0.id.isEmpty }
            }
            return !self.selectedDevice.isEmpty
        }

        locationHold.log = { [weak self] message in
            self?.log(message)
        }

        locationHold.onStateChange = { [weak self] state in
            guard let self else { return }
            self.holdSummary = Self.describe(state)
            self.holdState = state
            self.announceIfLost(state)
        }

        configureDayPlan()
    }

    /// The Mac is usually not being watched while a point is held, so a lost hold has to
    /// announce itself rather than sit quietly in a panel.
    private func announceIfLost(_ state: LocationHoldSupervisor.State) {
        guard case .failed = state else {
            wasHoldLost = false
            return
        }
        guard !wasHoldLost else { return }
        wasHoldLost = true
        announceLoss()
    }

    /// Says out loud that the device is no longer where the app claims it is.
    private func announceLoss() {
        NSSound.beep()
        _ = NSApplication.shared.requestUserAttention(.criticalRequest)
    }

    /// `true` when the target can hold a point with a long-lived `simulate-location play`
    /// session. Simulator and Android have no session to keep open and are re-applied on
    /// the timer instead.
    private var usesPlaybackHold: Bool {
        platform == .iOS && deviceMode == .device && useRSD
    }

    /// Applies the held point using whichever mechanism actually keeps it applied.
    ///
    /// On a real device that means one `simulate-location play` process walking a file of
    /// identical points: the DVT session stays open for as long as it runs, so the point
    /// is never handed back. `simulate-location set` cannot do this — the device reverts
    /// the moment that process exits, so re-running it just alternates between the held
    /// point and real GPS.
    private func applyHeldLocation(_ coordinate: CLLocationCoordinate2D) {
        guard usesPlaybackHold else {
            run(location: coordinate)
            return
        }

        let gpxURL: URL
        do {
            gpxURL = try GPXRoute.writeStationary(coordinate: coordinate)
        } catch {
            reportInjectionFailure(error)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runner.playRoute(
                    gpxURL: gpxURL,
                    connection: self.iosConnection,
                    activityLabel: "Location set",
                    showAlert: self.showAlert
                )
            } catch {
                self.reportInjectionFailure(error)
            }
        }
    }

    // MARK: - Day plan

    private func configureDayPlan() {
        dayPlan = dayPlanStore.load()

        dayPlanRunner.log = { [weak self] message in self?.log(message) }

        dayPlanRunner.onActivityChange = { [weak self] activity in
            self?.dayActivity = activity
        }

        dayPlanRunner.holdPoint = { [weak self] coordinate in
            self?.locationHold.hold(coordinate)
        }

        dayPlanRunner.playLeg = { [weak self] path, speedKph, duration in
            self?.playPlanLeg(path: path, speedKph: speedKph, duration: duration)
        }

        // A leg with no session behind it is a device that has quietly stopped moving.
        // A disconnected device counts as alive here on purpose: the reconnect path
        // resumes the plan itself, and reporting "dead" meanwhile would have the runner
        // restart a leg every two seconds against a phone that is not there.
        dayPlanRunner.isLegSessionAlive = { [weak self] in
            guard let self, self.usesPlaybackHold else { return true }
            guard !self.selectedDevice.isEmpty else { return true }
            return self.runner.isPlaybackRunning
        }

        dayPlanRunner.onFinished = { [weak self] in
            self?.dayActivity = .stopped
        }
    }

    /// Adds the pin currently on the map as the next stop.
    func addDayStop() {
        guard let point = mapScene.annotationEndpoints().first?.coordinate else {
            showAlert("Drop a pin on the map first")
            return
        }

        // The previous last stop needs a departure time now that something follows it.
        if !dayPlan.stops.isEmpty, dayPlan.stops[dayPlan.stops.count - 1].departureMinutes == nil {
            dayPlan.stops[dayPlan.stops.count - 1].departureMinutes = defaultDeparture()
        }

        dayPlan.stops.append(
            DayPlanStop(
                name: "Stop \(dayPlan.stops.count + 1)",
                latitude: point.latitude,
                longitude: point.longitude,
                departureMinutes: nil
            )
        )

        daySchedule = nil
    }

    func removeDayStop(at index: Int) {
        guard dayPlan.stops.indices.contains(index) else { return }
        dayPlan.stops.remove(at: index)
        if var last = dayPlan.stops.last {
            last.departureMinutes = nil
            dayPlan.stops[dayPlan.stops.count - 1] = last
        }
        daySchedule = nil
    }

    func showDayStopOnMap(at index: Int) {
        guard dayPlan.stops.indices.contains(index) else { return }
        let stop = dayPlan.stops[index]
        putLocationOnMap(location: Location(name: stop.name, latitude: stop.latitude, longitude: stop.longitude))
    }

    /// An hour after the previous departure, or the next round hour from now.
    private func defaultDeparture() -> Int {
        if let previous = dayPlan.stops.dropLast().last?.departureMinutes {
            return min(previous + 60, 23 * 60 + 59)
        }
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return min(((now.hour ?? 8) + 1) * 60, 23 * 60 + 59)
    }

    /// Routes every leg and works out the timetable.
    @MainActor
    func buildDaySchedule() async {
        guard dayPlan.stops.count >= 2 else {
            daySchedule = DaySchedule(stops: dayPlan.stops, legs: [])
            dayPlanStatus = dayPlan.stops.isEmpty ? "Add a stop to begin." : nil
            return
        }

        dayPlanStatus = "Working out the day…"

        var distances: [CLLocationDistance] = []
        var paths: [[Coordinate]] = []

        for index in 0..<(dayPlan.stops.count - 1) {
            do {
                let leg = try await RouteFinder.route(
                    from: dayPlan.stops[index].coordinate,
                    to: dayPlan.stops[index + 1].coordinate,
                    transportType: transportType
                )
                distances.append(leg.distance)
                paths.append(leg.path)
            } catch {
                dayPlanStatus = "Could not route \(dayPlan.stops[index].name) → \(dayPlan.stops[index + 1].name): \(error.localizedDescription)"
                daySchedule = nil
                return
            }
        }

        let schedule = DaySchedule.build(plan: dayPlan, on: Date(), distances: distances, paths: paths)
        daySchedule = schedule
        dayPlanStatus = Self.describeDay(schedule)
    }

    /// Anything about the worked-out day worth saying before it is run.
    ///
    /// A day whose last arrival has already passed still runs — it parks at the final
    /// stop and stays there — which is correct but looks broken. Times are read against
    /// today, so a plan set up late at night is the usual way to land there.
    private static func describeDay(_ schedule: DaySchedule) -> String? {
        if let last = schedule.legs.last, last.arrival < Date() {
            return "Every departure in this plan is earlier than the current time, so running it now parks at the last stop. Times are read against today."
        }
        if schedule.hasSlippedLegs {
            return "Some legs cannot finish before the next departure — those departures have moved later."
        }
        return nil
    }

    func startDayPlan() {
        guard let daySchedule else {
            showAlert("Work out the day first")
            return
        }
        // Whatever is driving the device now is about to be wrong: the plan decides
        // from the clock what should be happening, and issues it on its first tick.
        // The whole simulation stops, not just the process — a route left marked as
        // playing would claim the plan's own leg endings as its own.
        stopSimulation()
        defaults.set(true, forKey: AppStorageKey.isRunningDayPlan)
        dayPlanRunner.start(daySchedule)
    }

    func stopDayPlan() {
        defaults.set(false, forKey: AppStorageKey.isRunningDayPlan)
        dayPlanRunner.stop()
        stopSimulation()
    }

    /// Picks a running day plan back up after a quit, a crash, or a Mac restart.
    ///
    /// A held point is already restored this way, and a day plan going quiet over the
    /// same gap would be the more surprising of the two. Nothing has to be remembered
    /// about where the day had got to: it is decided from the clock, so working the day
    /// out again and starting it lands wherever the day is now.
    private func resumeDayPlanIfNeeded() {
        guard defaults.bool(forKey: AppStorageKey.isRunningDayPlan) else { return }

        guard dayPlan.stops.count >= 2 else {
            defaults.set(false, forKey: AppStorageKey.isRunningDayPlan)
            return
        }

        log("Picking the day plan back up from the previous run")

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.buildDaySchedule()

            guard let schedule = self.daySchedule else {
                // buildDaySchedule has already said why in dayPlanStatus.
                self.log("Could not work the day out again — the plan is loaded but not running")
                self.defaults.set(false, forKey: AppStorageKey.isRunningDayPlan)
                return
            }

            self.dayPlanRunner.start(schedule)
        }
    }

    /// The target changed while a point was being held: put it on the new one now.
    ///
    /// Which target a held point goes to is decided each time it is applied, not when
    /// the hold starts, so changing the target used to leave the point on the old one
    /// until the next keep-alive tick happened to move it — with the old session still
    /// running, and nothing saying the two disagreed. The old session is torn down and
    /// the point re-issued immediately instead.
    private func retargetHold() {
        guard locationHold.isHolding else { return }
        log("target changed while holding a point — re-applying it to the new target")
        runner.stopRoutePlayback()
        locationHold.reapply(trigger: .targetChanged)
    }

    /// Picks a route back up after the device came back.
    ///
    /// Playback is re-issued from the last point the device reported, so an interrupted
    /// drive continues rather than restarting. A route that had already reached its end
    /// when the device went away has nothing left to drive, so its endpoint is held —
    /// which is what would have happened had the device stayed.
    private func resumeRouteAfterReconnect() {
        guard isSimulating, isPlayingRoute else { return }

        let remainingCount = playbackPosition
            .map { playbackCoordinates.count - Polyline.nearestVertex(to: $0, in: playbackCoordinates) }
            ?? playbackCoordinates.count

        guard remainingCount > 1 else {
            log("the route had finished while the device was away — holding its endpoint")
            isPlayingRoute = false
            isSimulating = false
            isPaused = false
            if let endpoint = playbackPosition ?? playbackCoordinates.last {
                holdLocation(endpoint)
            }
            return
        }

        log("device is back — resuming the route from where it stopped")
        isPaused = false
        restartPlaybackFromCurrentPosition()
    }

    /// A route playback process ended without being told to.
    ///
    /// Only a user-started route is finished here. The stationary hold and day-plan
    /// legs play through the same command, but the hold supervisor and the plan's tick
    /// restart those themselves — and both run with `isPlayingRoute` false.
    private func handleRoutePlaybackFinished(succeeded: Bool) {
        guard isPlayingRoute else { return }

        // The device going away is what ended this, not the road running out. Holding
        // now would spawn a session against a connection that no longer exists, and
        // would throw away the route in the process. Stay paused; the reconnect picks
        // it up, and holds the endpoint there if the drive had in fact finished.
        guard !connectedDevices.isEmpty else {
            isPaused = true
            log("route playback stopped with the device away — it resumes when the device returns")
            return
        }

        isPlayingRoute = false
        isSimulating = false
        isPaused = false
        timer?.invalidate()
        timer = nil
        currentTrackIndex = 0

        // Arrived or died, the device must not drift back to real GPS: hold wherever
        // the drive got to. On a clean finish that is the destination.
        guard let endpoint = playbackPosition ?? playbackCoordinates.last else { return }
        log(succeeded
            ? "route finished — holding the destination"
            : "route playback ended early — holding the last played point")
        holdLocation(endpoint)
    }

    /// Writes the GPX for a stretch of driving, realistic or constant-speed.
    ///
    /// - Parameters:
    ///   - fraction: how much of the whole route this is, so a partial replay after a
    ///     pause gets its share of the traffic-adjusted duration rather than all of it.
    ///   - seed: keeps the lights in the same places when a route is replayed part-way
    ///     through, so resuming does not reshuffle the drive.
    private func writeDriveGPX(
        coordinates: [CLLocationCoordinate2D],
        speedKph: Double,
        expectedTravelTime: TimeInterval,
        fraction: Double = 1.0,
        seed: UInt64
    ) throws -> URL {
        guard isRealisticDriving else {
            return try GPXRoute.write(coordinates: coordinates, speed: max(speedKph, 1) / 3.6)
        }

        let target = expectedTravelTime > 0 ? expectedTravelTime * max(min(fraction, 1), 0.01) : nil
        let samples = DriveProfile.build(
            path: coordinates,
            settings: .init(cruiseSpeed: max(speedKph, 1) / 3.6, seed: seed),
            targetDuration: target
        )

        if let arrival = samples.last?.offset {
            let minutes = Int((arrival / 60).rounded())
            let matched = target.map { abs(arrival - $0) / $0 < 0.05 } ?? false
            let how: String
            if matched {
                how = " (matched to the routing estimate, traffic included)"
            } else if target != nil {
                // The clamp refused a stretch or squash this extreme; the drive is as
                // close as physics allows, and this is the duration it actually takes.
                how = " (estimate and speed too far apart to match fully)"
            } else {
                how = " (no live estimate — modelled)"
            }
            log("realistic drive: \(samples.count) points, about \(minutes) min" + how)
        }

        return try GPXRoute.write(samples: samples)
    }

    /// A stable seed for one route, so its lights do not move between replays.
    ///
    /// Not `Hasher`: that is salted differently on every launch of the app, which would
    /// have reshuffled the drive across a restart — including the day plan resuming
    /// after one. SplitMix is the same mixer the profile's own generator uses.
    private static func driveSeed(for coordinates: [CLLocationCoordinate2D]) -> UInt64 {
        guard let first = coordinates.first, let last = coordinates.last else { return 1 }

        func mix(_ state: UInt64, _ value: UInt64) -> UInt64 {
            var z = (state ^ value) &+ 0x9E37_79B9_7F4A_7C15
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        var seed: UInt64 = 0x5D8E_7C31_A2B4_96F1
        for value in [first.latitude, first.longitude, last.latitude, last.longitude] {
            seed = mix(seed, UInt64(bitPattern: Int64((value * 10_000).rounded())))
        }
        seed = mix(seed, UInt64(coordinates.count))
        return seed == 0 ? 1 : seed
    }

    private func playPlanLeg(path: [Coordinate], speedKph: Double, duration: TimeInterval) {
        // A leg is movement, not a held point: let go of the hold so the two are not
        // both driving the device.
        locationHold.release()

        let coordinates = path.map { $0.clCoordinate }
        let url: URL
        do {
            // The plan already decided when this leg arrives, so a realistic drive is
            // fitted to that rather than being allowed to set its own pace. The stops and
            // braking are real; the arrival time stays the one on the timetable.
            url = try writeDriveGPX(
                coordinates: coordinates,
                speedKph: speedKph,
                expectedTravelTime: duration,
                seed: Self.driveSeed(for: coordinates)
            )
        } catch {
            reportInjectionFailure(error)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runner.playRoute(
                    gpxURL: url,
                    connection: self.iosConnection,
                    activityLabel: "Following the day plan",
                    showAlert: self.showAlert
                )
            } catch {
                self.reportInjectionFailure(error)
            }
        }
    }

    /// Applies `coordinate` and keeps it applied, rather than setting it once.
    private func holdLocation(_ coordinate: CLLocationCoordinate2D) {
        persistHeldPoint(coordinate)
        locationHold.hold(coordinate)
    }

    /// Remembers the held point so a crash, a forced quit, or a Mac restart resumes it on
    /// the next launch instead of leaving the device on real GPS with nobody watching.
    private func persistHeldPoint(_ coordinate: CLLocationCoordinate2D?) {
        guard let coordinate else {
            defaults.set(false, forKey: AppStorageKey.isHolding)
            return
        }
        defaults.set(coordinate.latitude, forKey: AppStorageKey.heldLatitude)
        defaults.set(coordinate.longitude, forKey: AppStorageKey.heldLongitude)
        defaults.set(true, forKey: AppStorageKey.isHolding)
    }

    private func restoreHeldPointIfNeeded() {
        // A resuming day plan decides where the device belongs; a point left over from
        // before the restart would only be somewhere the plan is about to move away from.
        guard !defaults.bool(forKey: AppStorageKey.isRunningDayPlan) else { return }
        guard defaults.bool(forKey: AppStorageKey.isHolding) else { return }

        let latitude = defaults.double(forKey: AppStorageKey.heldLatitude)
        let longitude = defaults.double(forKey: AppStorageKey.heldLongitude)

        guard CoordinateParsing.isValid(latitude: latitude, longitude: longitude),
              !(latitude == 0 && longitude == 0) else {
            defaults.set(false, forKey: AppStorageKey.isHolding)
            return
        }

        log("Resuming the location hold left over from the previous run")

        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        if pointsMode == .single {
            putLocationOnMap(location: Location(name: "", latitude: latitude, longitude: longitude))
        }
        locationHold.hold(coordinate)
    }

    /// Pushes the held point again on demand.
    func reapplyHeldLocation() {
        locationHold.reapply(trigger: .manual)
    }

    private static func describe(_ state: LocationHoldSupervisor.State) -> String? {
        switch state {
        case .idle:
            return nil
        case .held(let point, let confirmedAt):
            return "Holding \(point.formatted) — confirmed \(holdTimeFormatter.string(from: confirmedAt))"
        case .applying(let point):
            return "Applying \(point.formatted)…"
        case .failed(let point, let reason):
            return "\(point.formatted) not applied — \(reason)"
        }
    }

    private static let holdTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func reportInjectionFailure(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.log("Could not apply the location: \(error.localizedDescription)")
            self.activity = .failed(error.localizedDescription)

            // showAlert used to end the simulation for every alert, wherever it came
            // from. A location that cannot be applied is the case that actually meant,
            // so it stops here instead — where it is about this device, not about a
            // background rescan that happened to have something to say.
            if self.isSimulating, !self.isPlayingRoute {
                self.isSimulating = false
                self.isPaused = false
                self.timer?.invalidate()
                self.timer = nil
            }
        }
    }

    private func run(location: CLLocationCoordinate2D) {
        defaults.set(platform.rawValue, forKey: AppStorageKey.platform)
        defaults.set(adbPath, forKey: AppStorageKey.adbPath)
        defaults.set(adbDeviceId, forKey: AppStorageKey.adbDeviceId)
        defaults.set(isEmulator, forKey: AppStorageKey.isEmulator)

        if platform == .android {
            runOnAndroid(location: location)
            return
        }
        if deviceMode == .device {
            if useRSD {
                // `try` inside a bare `Task` discards the error: a failure to even build
                // the command used to vanish without a word.
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.runner.runOnNewIos(
                            location: location,
                            connection: self.iosConnection,
                            showAlert: self.showAlert
                        )
                    } catch {
                        self.reportInjectionFailure(error)
                    }
                }

            } else {
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.runner.runOnIos(
                            location: location,
                            showAlert: self.showAlert
                        )
                    } catch {
                        self.reportInjectionFailure(error)
                    }
                }
            }
        } else {
            // Nothing to send it to. This used to alert and then carry on, logging
            // "set simulator location" for a simulator that does not exist, which read
            // as a location that had been applied.
            guard !bootedSimulators.isEmpty else {
                isSimulating = false
                locationHold.targetLost(reason: SimulatorFetchError.noBootedSimulators.description)
                showAlert(SimulatorFetchError.noBootedSimulators.description)
                return
            }
            runner.runOnSimulator(
                location: location,
                selectedSimulator: selectedSimulator,
                bootedSimulators: bootedSimulators,
                showAlert: showAlert
            )
        }
    }

    private func runOnAndroid(location: CLLocationCoordinate2D) {
        if adbDeviceId.isEmpty {
            showAlert("Please specify device id")
            return
        }

        if adbPath.isEmpty {
            showAlert("Please specify path to adb")
            return
        }

        log("""
        Run on android
        - location: \(location)
        - adbDeviceId: \(adbDeviceId)
        - adbPath: \(adbPath)
        - isEmulator: \(isEmulator)
        """)
        runner.runOnAndroid(
            location: location,
            adbDeviceId: adbDeviceId,
            adbPath: adbPath,
            isEmulator: isEmulator,
            showAlert: showAlert
        )
    }

    private func makeDeveloperImageDmgPath(iOSVersion: String) -> String {
        "\(xcodePath)\(iOSDeveloperImagePath)\(iOSVersion)\(iOSDeveloperImageDmg)"
    }

    private func makeDeveloperImageSignaturePath(iOSVersion: String) -> String {
        "\(xcodePath)\(iOSDeveloperImagePath)\(iOSVersion)\(iOSDeveloperImageSignature)"
    }

    /// Records a line for the Logs pane.
    ///
    /// Called from process termination handlers, discovery, and the device monitor —
    /// none of which are on the main thread — and `logs` is `@Published`, so writing it
    /// where it is called from was one of the ways to wedge SwiftUI's publishing lock.
    /// The timestamp is taken here rather than on arrival so a hop does not skew it.
    private func log(_ message: String) {
        let now = Date()
        let entry = LogEntry(date: now, message: message, stamp: Self.logTimeFormatter.string(from: now))
        Self.onMain { [weak self] in
            guard let self else { return }

            // A failure that repeats on a timer — a missing simctl probed every three
            // seconds, say — would otherwise push every other line out of the capped log
            // within hours, which is the opposite of what a failure log is for. The line
            // stays, and keeps its count, rather than being dropped.
            if let first = self.logs.first, first.message == entry.message {
                self.repeatedLogCount += 1
                self.logs[0] = LogEntry(
                    date: now,
                    message: "\(entry.message)  (\(self.repeatedLogCount + 1)x, latest \(entry.stamp))",
                    stamp: first.stamp
                )
                return
            }
            self.repeatedLogCount = 0

            self.logs.insert(entry, at: 0)
            // Bounded, because nothing else ever shrinks this and the pane redraws it.
            // Deliberately generous: at the noisiest polling rate a small cap would be a
            // few minutes of history, and a disconnect from twenty minutes ago is exactly
            // what someone opens this pane to find.
            if self.logs.count > Self.maxLogEntries {
                self.logs.removeLast(self.logs.count - Self.maxLogEntries)
            }
        }
    }

    /// How many log lines are kept. Newest are at index 0, so the oldest fall off the end.
    private static let maxLogEntries = 5_000

    private static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    /// Runs `work` on the main thread, straight away when already there.
    ///
    /// Every `@Published` write has to land on the main thread. SwiftUI takes a lock to
    /// publish, and a write from a background thread can hold that lock while waiting for
    /// main at the same moment main is waiting for the lock — which freezes the window
    /// with no crash and nothing in the log to say so.
    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
    
    func clearLogs() {
        logs.removeAll()
    }

    private static func presentPymobileDeviceOutput(stdout: Data, stderr: Data, showAlert: @escaping (String) -> Void) {
        let err = String(data: stderr, encoding: .utf8) ?? ""
        let out = String(data: stdout, encoding: .utf8) ?? ""

        if !err.isEmpty {
            if err.range(of: "{'Error': 'DeviceLocked'}") != nil {
                showAlert("Error: Device is locked")
            } else {
                showAlert(err)
            }
        }

        if !out.isEmpty {
            showAlert(out)
        }
    }
}

extension CLLocation {

    static func distance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> CLLocationDistance {
        let from = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let to = CLLocation(latitude: to.latitude, longitude: to.longitude)
        return from.distance(from: to)
    }
}
