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

    /// `true` while a route (or A→B) playback is running.
    @Published var isSimulating = false

    /// What the app can actually promise about the simulated location right now.
    @Published var holdStatus: LocationHoldStatus = .idle

    @Published var speed: Double = 60.0
    @Published var pointsMode: PointsMode = .single {
        didSet { mapScene.handlePointsModeChange(to: pointsMode) }
    }
    @Published var deviceMode: DeviceMode = .simulator {
        didSet {
            guard deviceMode != oldValue else { return }
            defaults.set(deviceMode.rawValue, forKey: AppStorageKey.deviceMode)
            // Leaving device mode must drop the helper that is still holding a
            // location on the phone, or it would keep running unnoticed.
            if oldValue == .device { runner.stop() }
            locationHold.reapplyNow(trigger: .settingsChanged)
        }
    }
    @Published var xcodePath: String = "/Applications/Xcode.app" {
        didSet { defaults.set(xcodePath, forKey: AppStorageKey.xcodePath) }
    }

    @Published var useRSD: Bool = false {
        didSet {
            guard useRSD != oldValue else { return }
            defaults.set(useRSD, forKey: AppStorageKey.useRSD)
            // Switching transport invalidates whatever session is open.
            runner.stop()
            locationHold.reapplyNow(trigger: .settingsChanged)
        }
    }

    @Published var bootedSimulators: [Simulator] = []
    @Published var selectedSimulator: String = "" {
        didSet { defaults.set(selectedSimulator, forKey: AppStorageKey.selectedSimulator) }
    }

    @Published var connectedDevices: [Device] = []
    @Published var selectedDevice: String = "" {
        didSet { defaults.set(selectedDevice, forKey: AppStorageKey.selectedDevice) }
    }

    @Published var showingAlert: Bool = false
    @Published var platform: AppPlatform = .iOS {
        didSet {
            guard platform != oldValue else { return }
            defaults.set(platform.rawValue, forKey: AppStorageKey.platform)
            if oldValue == .iOS { runner.stop() }
            locationHold.reapplyNow(trigger: .settingsChanged)
        }
    }
    @Published var adbPath: String = "" {
        didSet { defaults.set(adbPath, forKey: AppStorageKey.adbPath) }
    }
    @Published var adbDeviceId: String = "" {
        didSet { defaults.set(adbDeviceId, forKey: AppStorageKey.adbDeviceId) }
    }
    @Published var isEmulator: Bool = false {
        didSet { defaults.set(isEmulator, forKey: AppStorageKey.isEmulator) }
    }

    @Published var rsdAddress: String = "" {
        didSet { defaults.set(rsdAddress, forKey: AppStorageKey.rsdAddress) }
    }
    @Published var rsdPort: String = "" {
        didSet { defaults.set(rsdPort, forKey: AppStorageKey.rsdPort) }
    }

    /// Re-applies the held point on a timer so it cannot quietly revert to real GPS.
    @Published var isKeepAliveEnabled: Bool = true {
        didSet {
            guard isKeepAliveEnabled != oldValue else { return }
            defaults.set(isKeepAliveEnabled, forKey: AppStorageKey.keepAliveEnabled)
            locationHold.isKeepAliveEnabled = isKeepAliveEnabled
        }
    }

    @Published var keepAliveInterval: Double = LocationHoldSupervisor.defaultKeepAliveInterval {
        didSet {
            guard keepAliveInterval != oldValue else { return }
            defaults.set(keepAliveInterval, forKey: AppStorageKey.keepAliveInterval)
            locationHold.keepAliveInterval = keepAliveInterval
        }
    }

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

    /// Keeps the log from growing without bound during a long drive.
    private static let maxLogEntries = 500

    /// Don't re-list booted simulators more often than this while injecting.
    private static let simulatorRefreshCooldown: TimeInterval = 4

    private let mapView: MapView
    private let mapScene: MapSceneCoordinator
    private let runner: DeviceLocationRunning
    private let savedLocationsStore: SavedLocationsStore
    private let locationHold = LocationHoldSupervisor()
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
    private var isRouteInjectionInFlight = false

    private var timer: Timer?

    private var lastSimulatorRefreshAt: Date?
    private var lastSimulatorListError: String?
    private var lastAlertText: String?
    private var lastAlertAt: Date?
    private var lastNotifiedSeverity: LocationHoldStatus.Severity = .neutral

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

        runner.log = { [weak self] message in
            self?.log(message)
        }

        restoreSettings()
        configureLocationHold()

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.startUpdatingLocation()
        locationManager.requestLocation()

        mapView.viewHolder.clickAction = { [weak self] gesture in
            guard let self else { return }
            self.mapScene.handleMapClick(gesture, pointsMode: self.pointsMode)
        }

        Task { @MainActor [weak self] in
            await self?.refreshDevices()
        }
    }

    // MARK: - Public

    @MainActor
    func refreshDevices(announceProblems: Bool = true) async {
        await refreshSimulators()
        await refreshConnectedDevices(announceProblems: announceProblems)
    }

    @MainActor
    private func refreshSimulators() async {
        lastSimulatorRefreshAt = Date()

        let previousSimulator = selectedSimulator
        let logSink: (String) -> Void = { [weak self] message in self?.log(message) }

        do {
            // `simctl` is a blocking child process; running it inline would freeze the
            // window every time the keep-alive re-checks which simulators are booted.
            let simulators = try await Task.detached(priority: .userInitiated) {
                try SimulatorDiscovery.fetchBootedSimulators(log: logSink)
            }.value

            // Assign only on change: this runs on every keep-alive tick, and a
            // `@Published` write would redraw the whole panel each time.
            if bootedSimulators != simulators {
                bootedSimulators = simulators
            }
            lastSimulatorListError = nil
        } catch {
            if !bootedSimulators.isEmpty {
                bootedSimulators = []
            }
            // This runs on every tick; logging an unchanged error each time would
            // bury everything else.
            let description = "\(error)"
            if lastSimulatorListError != description {
                lastSimulatorListError = description
                log("Could not list booted simulators: \(description)")
            }
        }

        // A refresh must never silently retarget a different simulator: that used to
        // send updates to a device the user was not looking at.
        if bootedSimulators.contains(where: { $0.id == previousSimulator }) {
            if selectedSimulator != previousSimulator {
                selectedSimulator = previousSimulator
            }
        } else {
            if !previousSimulator.isEmpty {
                log("Previously selected simulator \(previousSimulator) is no longer booted")
            }
            selectedSimulator = bootedSimulators.first?.id ?? ""
        }
    }

    @MainActor
    private func refreshConnectedDevices(announceProblems: Bool) async {
        let previousDevice = selectedDevice

        do {
            let devices = try await IOSUSBDeviceDiscovery.fetchConnectedDevices(
                runner: runner,
                showAlert: { [weak self] message in
                    guard announceProblems else { return }
                    self?.showAlert(message)
                },
                log: { [weak self] in self?.log($0) }
            )
            if connectedDevices != devices {
                connectedDevices = devices
            }
        } catch {
            if !connectedDevices.isEmpty {
                connectedDevices = []
            }
            log("Could not list connected iOS devices: \(error.localizedDescription)")
        }

        if connectedDevices.contains(where: { $0.id == previousDevice }) {
            if selectedDevice != previousDevice {
                selectedDevice = previousDevice
            }
        } else {
            if !previousDevice.isEmpty {
                log("Previously selected device \(previousDevice) is no longer connected")
            }
            selectedDevice = connectedDevices.first?.id ?? ""
        }
    }

    func setCurrentLocation() {
        guard let location = locationManager.location?.coordinate else {
            showAlert("Current location is unavailable")
            return
        }
        if pointsMode == .single {
            // Show where the hold actually is; in two-point mode this would eat a slot.
            putLocationOnMap(location: Location(name: "", latitude: location.latitude, longitude: location.longitude))
        }
        hold(location)
    }

    func setSelectedLocation(toBPoint: Bool = false) {
        let endpoints = mapScene.annotationEndpoints()
        if toBPoint {
            guard endpoints.count == 2 else {
                showAlert("Point B is not selected")
                return
            }
            hold(endpoints[1].coordinate)
        } else {
            guard let annotation = endpoints.first else {
                showAlert("Point A is not selected")
                return
            }
            hold(annotation.coordinate)
        }
    }

    func makeRoute() {
        mapScene.makeRoute(showAlert: showAlert)
    }

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

        startRoutePlayback()
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

        startRoutePlayback()
    }

    func updateMapRegion(force: Bool = false) {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
            return
        }

        // Only ask once, on first determination. The old code re-requested on every
        // single location update, which is a lot of churn while driving.
        guard !isMapCentered || force, let location = locationManager.location else {
            return
        }

        isMapCentered = true

        mapView.mkMapView.showsUserLocation = true

        let viewRegion = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000)
        let adjustedRegion = mapView.mkMapView.regionThatFits(viewRegion)

        mapView.mkMapView.setRegion(adjustedRegion, animated: true)
    }

    func prepareEmulator() {
        guard validateAdbSettings() else { return }

        executeAdbCommand(args: ["shell", "settings", "put", "secure", "location_providers_allowed", "+gps"])
        executeAdbCommand(
            args: ["shell", "settings", "put", "secure", "location_providers_allowed", "+network"],
            successMessage: "Emulator is ready"
        )
    }

    func installHelperApp() {
        guard validateAdbSettings() else { return }

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

    /// Stops route playback and releases any held point.
    func stopSimulation() {
        stopRoutePlayback()
        locationHold.release(reason: "Stopped by the user")
        runner.stop()
    }

    /// Pushes the held point again right now.
    func reapplyHeldLocation() {
        locationHold.reapplyNow(trigger: .manual)
    }

    func reset() {
        stopRoutePlayback()
        locationHold.release(reason: "Reset")
        mapScene.resetMapVisuals()

        if platform == .android {
            guard validateAdbSettings() else { return }
            runner.resetAndroid(adbDeviceId: adbDeviceId, adbPath: adbPath, showAlert: showAlert)
        } else if deviceMode == .device {
            if useRSD {
                runner.resetNewIos(rsdAddress: rsdAddress, rsdPort: rsdPort, showAlert: showAlert)
            } else {
                runner.resetIos(showAlert: showAlert)
            }
        } else {
            runner.stop()
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
                let result = try ProcessRunner.run(task, timeout: 120)
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
                let result = try ProcessRunner.run(task, timeout: 120)
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

    func showAlert(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            self.log("Alert: \(text)")

            // A failing keep-alive can produce the same message every few seconds;
            // one modal is informative, twenty is a wall the user cannot dismiss.
            if self.lastAlertText == text,
               let lastAlertAt = self.lastAlertAt,
               Date().timeIntervalSince(lastAlertAt) < 30 {
                return
            }

            self.lastAlertText = text
            self.lastAlertAt = Date()
            self.alertText = text
            self.showingAlert = true
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
        hold(CLLocationCoordinate2D(latitude: lat, longitude: lng))
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
        log(error.localizedDescription)
    }

    // MARK: - Private

    private func restoreSettings() {
        if let storedPlatform = AppPlatform(rawValue: defaults.integer(forKey: AppStorageKey.platform)) {
            platform = storedPlatform
        }
        if let storedDeviceMode = DeviceMode(rawValue: defaults.integer(forKey: AppStorageKey.deviceMode)) {
            deviceMode = storedDeviceMode
        }

        useRSD = defaults.bool(forKey: AppStorageKey.useRSD)
        rsdAddress = defaults.string(forKey: AppStorageKey.rsdAddress) ?? ""
        rsdPort = defaults.string(forKey: AppStorageKey.rsdPort) ?? ""
        adbPath = defaults.string(forKey: AppStorageKey.adbPath) ?? ""
        adbDeviceId = defaults.string(forKey: AppStorageKey.adbDeviceId) ?? ""
        isEmulator = defaults.bool(forKey: AppStorageKey.isEmulator)
        xcodePath = defaults.string(forKey: AppStorageKey.xcodePath) ?? "/Applications/Xcode.app"
        selectedSimulator = defaults.string(forKey: AppStorageKey.selectedSimulator) ?? ""
        selectedDevice = defaults.string(forKey: AppStorageKey.selectedDevice) ?? ""

        isKeepAliveEnabled = defaults.object(forKey: AppStorageKey.keepAliveEnabled) as? Bool ?? true

        let storedInterval = defaults.double(forKey: AppStorageKey.keepAliveInterval)
        keepAliveInterval = storedInterval > 0 ? storedInterval : LocationHoldSupervisor.defaultKeepAliveInterval

        savedLocations = savedLocationsStore.load()
    }

    private func configureLocationHold() {
        locationHold.isKeepAliveEnabled = isKeepAliveEnabled
        locationHold.keepAliveInterval = keepAliveInterval

        locationHold.log = { [weak self] message in
            self?.log(message)
        }

        locationHold.inject = { [weak self] coordinate in
            guard let self else {
                return .failure(reason: "SimVirtualLocation is shutting down.")
            }
            return await self.applyLocation(coordinate)
        }

        locationHold.isSessionAlive = { [weak self] in
            guard let self, self.platform == .iOS, self.deviceMode == .device else { return false }
            return self.runner.isHoldingSession
        }

        locationHold.consumeSessionFailureReason = { [weak self] in
            self?.runner.consumeHoldFailureReason()
        }

        locationHold.onStatusChange = { [weak self] status in
            self?.handleHoldStatusChange(status)
        }
    }

    /// Starts (or moves) the held point. A held point and route playback are mutually
    /// exclusive, so playback is stopped first.
    private func hold(_ coordinate: CLLocationCoordinate2D) {
        stopRoutePlayback()
        locationHold.hold(coordinate)
    }

    private func handleHoldStatusChange(_ status: LocationHoldStatus) {
        holdStatus = status

        let severity = status.severity
        defer { lastNotifiedSeverity = severity }

        guard severity == .warning || severity == .error, severity != lastNotifiedSeverity else {
            return
        }

        // The user is very likely driving and not watching the window. Make the app
        // announce itself instead of failing quietly behind a green label.
        NSSound.beep()
        _ = NSApplication.shared.requestUserAttention(
            severity == .error ? .criticalRequest : .informationalRequest
        )
    }

    @MainActor
    private func applyLocation(_ location: CLLocationCoordinate2D) async -> InjectionOutcome {
        if platform == .android {
            guard !adbDeviceId.isEmpty else {
                return .failure(reason: "Specify the Android device id.")
            }
            guard !adbPath.isEmpty else {
                return .failure(reason: "Specify the path to adb.")
            }

            log("""
            Run on android
            - location: \(location)
            - adbDeviceId: \(adbDeviceId)
            - adbPath: \(adbPath)
            - isEmulator: \(isEmulator)
            """)

            return await runner.runOnAndroid(
                location: location,
                adbDeviceId: adbDeviceId,
                adbPath: adbPath,
                isEmulator: isEmulator
            )
        }

        if deviceMode == .device {
            if useRSD {
                return await runner.runOnNewIos(location: location, rsdAddress: rsdAddress, rsdPort: rsdPort)
            }
            return await runner.runOnIos(location: location)
        }

        // The simulator transport is a fire-and-forget notification, so the booted
        // list is the only evidence there is anything listening. Re-listing before
        // each injection is what turns "shut down while you were driving" from a
        // silent no-op into a reported failure — and lets a re-booted simulator
        // recover on its own.
        if shouldRefreshSimulators() {
            await refreshSimulators()
        }

        return await runner.runOnSimulator(
            location: location,
            selectedSimulator: selectedSimulator,
            bootedSimulators: bootedSimulators
        )
    }

    private func shouldRefreshSimulators() -> Bool {
        guard let lastSimulatorRefreshAt else { return true }
        return Date().timeIntervalSince(lastSimulatorRefreshAt) > Self.simulatorRefreshCooldown
    }

    private func validateAdbSettings() -> Bool {
        if adbDeviceId.isEmpty {
            showAlert("Please specify device id")
            return false
        }

        if adbPath.isEmpty {
            showAlert("Please specify path to adb")
            return false
        }

        return true
    }

    private func persistSavedLocations() {
        savedLocationsStore.save(savedLocations)
    }

    private func startRoutePlayback() {
        timer?.invalidate()
        timer = nil
        isSimulating = true
        isRouteInjectionInFlight = false
        lastTrackLocation = nil
        currentTrackIndex = 0

        locationHold.beginRoute()

        let timer = Timer(timeInterval: timeScale, repeats: true) { [weak self] _ in
            self?.performMovement()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopRoutePlayback() {
        timer?.invalidate()
        timer = nil
        isSimulating = false
        isRouteInjectionInFlight = false
        currentTrackIndex = 0
    }

    private func performMovement() {
        guard isSimulating, tracks.count > 0, currentTrackIndex < tracks.count else {
            stopRoutePlayback()
            locationHold.release(reason: "Route playback finished")
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
            sendRouteUpdate(to: to)
            mapScene.placeSimulationAnnotation(at: to)
            log("move to — distance=\(CLLocation.distance(from: from, to: to)), speed=\(moveSpeed)")

        case .finishTo(to: let to, from: let from, withSpeed: let moveSpeed):
            lastTrackLocation = nil
            currentTrackIndex += 1
            sendRouteUpdate(to: to)
            mapScene.placeSimulationAnnotation(at: to)
            log("finish to — distance=\(CLLocation.distance(from: from, to: to)), speed=\(moveSpeed)")
        }

        tracksTimes[track] = (tracksTimes[track] ?? 0) + timeScale
    }

    private func sendRouteUpdate(to coordinate: CLLocationCoordinate2D) {
        guard !isRouteInjectionInFlight else {
            log("Skipped a route update: the previous one has not finished yet")
            return
        }

        isRouteInjectionInFlight = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.applyLocation(coordinate)
            self.isRouteInjectionInFlight = false
            self.locationHold.record(outcome)
        }
    }

    private func executeAdbCommand(args: [String], successMessage: String? = nil) {
        guard validateAdbSettings() else { return }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: adbPath)
        task.arguments = args

        // `adb install` can take a minute; running it inline froze the whole window.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let result = try ProcessRunner.run(task, timeout: 120)
                let errorText = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)

                if result.terminationStatus != 0 || !errorText.isEmpty {
                    self.showAlert(Runner.describeFailure(
                        status: result.terminationStatus,
                        stdout: result.stdoutText,
                        stderr: result.stderrText
                    ))
                } else if let successMessage = successMessage {
                    self.showAlert(successMessage)
                }
            } catch {
                self.showAlert(error.localizedDescription)
            }
        }
    }

    private func printTimesToLog() {
        tracksTimes.forEach { track, time in
            let distance = CLLocation.distance(from: track.startPoint.coordinate, to: track.endPoint.coordinate)
            let avgSpeed = distance / time
            log("Track result: speed=\(avgSpeed * 3.6) km/h, distance=\(distance), time=\(time)")
        }
    }

    private func makeDeveloperImageDmgPath(iOSVersion: String) -> String {
        "\(xcodePath)\(iOSDeveloperImagePath)\(iOSVersion)\(iOSDeveloperImageDmg)"
    }

    private func makeDeveloperImageSignaturePath(iOSVersion: String) -> String {
        "\(xcodePath)\(iOSDeveloperImagePath)\(iOSVersion)\(iOSDeveloperImageSignature)"
    }

    /// Safe to call from any thread — the runner and the pipe drains log off the main
    /// thread, and `logs` is a `@Published` property.
    private func log(_ message: String) {
        if Thread.isMainThread {
            appendLog(message)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.appendLog(message)
            }
        }
    }

    private func appendLog(_ message: String) {
        logs.insert(LogEntry(date: Date(), message: message), at: 0)
        if logs.count > Self.maxLogEntries {
            logs.removeLast(logs.count - Self.maxLogEntries)
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
