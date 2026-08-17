//
//  Runner.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 19.05.2022.
//

import Foundation
import CoreLocation

enum RunnerError: LocalizedError {
    case pymobiledeviceNotFound(String)

    var errorDescription: String? {
        switch self {
        case .pymobiledeviceNotFound(let message):
            return message
        }
    }
}

class Runner {

    // MARK: - Internal Properties

    var timeDelay: TimeInterval = 0.5
    var log: ((String) -> Void)?
    var pymobiledevicePath: String?

    /// `true` while a long-lived helper process is holding a device session open.
    ///
    /// On iOS 17+ the DVT location channel closes with the process, so an alive
    /// process *is* the hold. The supervisor uses this to skip a redundant
    /// re-injection, and to notice the moment the session dies.
    var isHoldingSession: Bool {
        holdLock.lock()
        defer { holdLock.unlock() }
        return holdProcess?.isRunning == true
    }

    /// Why the last long-lived session ended, when it ended on its own.
    /// Reading it clears it, so a reason is reported once.
    func consumeHoldFailureReason() -> String? {
        holdLock.lock()
        defer { holdLock.unlock() }
        let reason = holdExitReason
        holdExitReason = nil
        return reason
    }

    // MARK: - Private Properties

    /// How long a one-shot injection may take before it is considered wedged.
    private static let injectionTimeout: TimeInterval = 25

    /// A helper still running after this long is holding the device session open
    /// rather than failing to finish, so it is adopted instead of killed.
    private static let sessionGracePeriod: TimeInterval = 6

    private let executionQueue = DispatchQueue(label: "com.simvirtuallocation.execution", qos: .userInitiated)

    private let holdLock = NSLock()
    private var holdProcess: Process?
    private var holdExitReason: String?
    /// Set while `stop()` tears things down, so a deliberate kill is not reported
    /// to the user as a failure.
    private var isStopping = false

    // MARK: - Internal Methods

    /// Ends any long-lived device session this app started.
    func stop() {
        holdLock.lock()
        let process = holdProcess
        isStopping = true
        holdProcess = nil
        holdExitReason = nil
        holdLock.unlock()

        if let process {
            log?("Ending the device session held by pid \(process.processIdentifier)")
            // Off the caller's thread: `stop()` runs on the main thread from the UI,
            // and escalating SIGTERM to SIGKILL can take a couple of seconds.
            DispatchQueue.global(qos: .userInitiated).async {
                process.terminateNow()
            }
        }

        holdLock.lock()
        isStopping = false
        holdLock.unlock()
    }

    func runOnSimulator(
        location: CLLocationCoordinate2D,
        selectedSimulator: String,
        bootedSimulators: [Simulator]
    ) async -> InjectionOutcome {
        // `Simulator.empty()` is the "To all simulators" row and carries no udid.
        let bootedIds = bootedSimulators.map { $0.id }.filter { !$0.isEmpty }

        guard !bootedIds.isEmpty else {
            return .failure(reason: SimulatorFetchError.noBootedSimulators.description)
        }

        let targets: [String]
        if selectedSimulator.isEmpty {
            targets = bootedIds
        } else {
            targets = bootedIds.filter { $0 == selectedSimulator }
            guard !targets.isEmpty else {
                // Previously this silently posted to nobody, so the map kept showing
                // a point the simulator had never been told about.
                return .failure(reason: "The selected simulator is no longer booted. Press Refresh and pick it again.")
            }
        }

        log?("set simulator location \(location.description) on \(targets.count) simulator(s)")

        NotificationSender.postNotification(for: location, to: targets)

        return .success
    }

    func runOnIos(location: CLLocationCoordinate2D) async -> InjectionOutcome {
        await inject(
            args: [
                "developer",
                "simulate-location",
                "set",
                "--",
                "\(String(format: "%.6f", location.latitude))",
                "\(String(format: "%.6f", location.longitude))"
            ],
            description: "set iOS location \(location.description)"
        )
    }

    func runOnNewIos(
        location: CLLocationCoordinate2D,
        rsdAddress: String,
        rsdPort: String
    ) async -> InjectionOutcome {
        guard !rsdAddress.isEmpty, !rsdPort.isEmpty else {
            return .failure(reason: "Specify the RSD address and port (see the help link under the iOS 17+ toggle).")
        }

        return await inject(
            args: [
                "developer",
                "dvt",
                "simulate-location",
                "set",
                "--rsd",
                rsdAddress,
                rsdPort,
                "--",
                "\(String(format: "%.6f", location.latitude))",
                "\(String(format: "%.6f", location.longitude))"
            ],
            description: "set iOS 17+ location \(location.description) via RSD \(rsdAddress):\(rsdPort)"
        )
    }

    func runOnAndroid(
        location: CLLocationCoordinate2D,
        adbDeviceId: String,
        adbPath: String,
        isEmulator: Bool
    ) async -> InjectionOutcome {
        let args: [String]
        if isEmulator {
            args = [
                "-s", adbDeviceId,
                "emu", "geo", "fix",
                "\(location.longitude)",
                "\(location.latitude)"
            ]
        } else {
            args = [
                "-s", adbDeviceId,
                "shell", "am", "broadcast",
                "-a", "send.mock",
                "-e", "lat", "\(location.latitude)",
                "-e", "lon", "\(location.longitude)"
            ]
        }

        let task = taskForAndroid(args: args, adbPath: adbPath)

        log?("set Android location \(location.description)")
        log?("task: \(task.logDescription)")

        return await withCheckedContinuation { (continuation: CheckedContinuation<InjectionOutcome, Never>) in
            executionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .failure(reason: "SimVirtualLocation is shutting down."))
                    return
                }

                do {
                    let result = try ProcessRunner.run(task, timeout: Runner.injectionTimeout)

                    if result.timedOut {
                        continuation.resume(returning: .failure(reason: "adb did not answer within \(Int(Runner.injectionTimeout))s — the device may be asleep or disconnected."))
                        return
                    }

                    if result.terminationStatus != 0 {
                        continuation.resume(returning: .failure(
                            reason: Runner.describeFailure(
                                status: result.terminationStatus,
                                stdout: result.stdoutText,
                                stderr: result.stderrText
                            )
                        ))
                        return
                    }

                    if let problem = Runner.diagnose(stdout: result.stdoutText, stderr: result.stderrText) {
                        continuation.resume(returning: .failure(reason: problem))
                        return
                    }

                    self.logToolOutput(stdout: result.stdoutText, stderr: result.stderrText)
                    continuation.resume(returning: .success)
                } catch {
                    continuation.resume(returning: .failure(reason: error.localizedDescription))
                }
            }
        }
    }

    func resetIos(showAlert: @escaping (String) -> Void) {
        stop()

        // Also tell the device to drop the simulated location. `stop()` alone only
        // ends our session; on transports that persist the point, it would stay.
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.inject(
                args: ["developer", "simulate-location", "clear"],
                description: "clear iOS simulated location",
                adoptLongRunningProcess: false
            )
            if let reason = outcome.failureReason {
                self.log?("Clearing the simulated location did not complete: \(reason)")
            }
        }
    }

    func resetNewIos(rsdAddress: String, rsdPort: String, showAlert: @escaping (String) -> Void) {
        stop()

        guard !rsdAddress.isEmpty, !rsdPort.isEmpty else { return }

        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.inject(
                args: ["developer", "dvt", "simulate-location", "clear", "--rsd", rsdAddress, rsdPort],
                description: "clear iOS 17+ simulated location",
                adoptLongRunningProcess: false
            )
            if let reason = outcome.failureReason {
                self.log?("Clearing the simulated location did not complete: \(reason)")
            }
        }
    }

    func resetAndroid(adbDeviceId: String, adbPath: String, showAlert: @escaping (String) -> Void) {
        let task = taskForAndroid(
            args: [
                "-s", adbDeviceId,
                "shell", "am", "broadcast",
                "-a", "stop.mock"
            ],
            adbPath: adbPath
        )

        executionQueue.async {
            do {
                let result = try ProcessRunner.run(task, timeout: Runner.injectionTimeout)
                if result.terminationStatus != 0 || result.timedOut {
                    let message = Runner.describeFailure(
                        status: result.terminationStatus,
                        stdout: result.stdoutText,
                        stderr: result.stderrText
                    )
                    Task { @MainActor in showAlert(message) }
                }
            } catch {
                Task { @MainActor in showAlert(error.localizedDescription) }
            }
        }
    }

    func taskForIOS(args: [String], showAlert: @escaping (String) -> Void) async throws -> Process {
        if pymobiledevicePath == nil || pymobiledevicePath?.isEmpty == true {
            pymobiledevicePath = findPymobiledevice3Path()
        }

        guard let validPath = pymobiledevicePath, !validPath.isEmpty else {
            let message = Runner.pymobiledeviceMissingMessage(pythonCheck: checkPythonInstallation())
            Task { @MainActor in showAlert(message) }
            throw RunnerError.pymobiledeviceNotFound(message)
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: validPath)
        task.arguments = args

        return task
    }

    // MARK: - Private Methods

    /// Runs a `pymobiledevice3` invocation and reports what actually happened.
    ///
    /// `adoptLongRunningProcess` keeps a helper that outlives the grace period alive
    /// and tracked, because on iOS 17+ the simulated location only lasts as long as
    /// that process does. One-shot commands (like `clear`) pass `false`.
    private func inject(
        args: [String],
        description: String,
        adoptLongRunningProcess: Bool = true
    ) async -> InjectionOutcome {
        let task: Process
        do {
            // Injections must not raise their own alerts: on a keep-alive tick that
            // would fire a modal every few seconds. The reason is returned instead.
            task = try await taskForIOS(args: args, showAlert: { _ in })
        } catch {
            return .failure(reason: error.localizedDescription)
        }

        log?(description)
        log?("task: \(task.logDescription)")

        return await withCheckedContinuation { (continuation: CheckedContinuation<InjectionOutcome, Never>) in
            executionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .failure(reason: "SimVirtualLocation is shutting down."))
                    return
                }
                let outcome = self.launch(task, adoptLongRunningProcess: adoptLongRunningProcess)
                continuation.resume(returning: outcome)
            }
        }
    }

    private func launch(_ task: Process, adoptLongRunningProcess: Bool) -> InjectionOutcome {
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        task.standardInput = FileHandle.nullDevice

        let outDrain = PipeDrain(outPipe)
        let errDrain = PipeDrain(errPipe)

        // Installed before `run()` so there is no window where the process can exit
        // unobserved and leave the hold looking healthy.
        task.terminationHandler = { [weak self] process in
            self?.handleTermination(of: process, outDrain: outDrain, errDrain: errDrain)
        }

        do {
            try task.run()
        } catch {
            return .failure(reason: error.localizedDescription)
        }

        if !task.wait(upTo: Runner.sessionGracePeriod) {
            if adoptLongRunningProcess {
                adopt(task)
                log?("pymobiledevice3 is holding the device session open (pid \(task.processIdentifier))")
                return .holding
            }

            if !task.wait(upTo: Runner.injectionTimeout - Runner.sessionGracePeriod) {
                task.terminateNow()
                return .failure(reason: "pymobiledevice3 did not finish within \(Int(Runner.injectionTimeout))s.")
            }
        }

        let status = task.terminationStatus
        let out = outDrain.text()
        let err = errDrain.text()

        guard status == 0 else {
            return .failure(reason: Runner.describeFailure(status: status, stdout: out, stderr: err))
        }

        // pymobiledevice3 writes ordinary progress logging to stderr. Treating any
        // stderr output as an error (the previous behaviour) raised alerts on healthy
        // runs; only genuine error markers count.
        if let problem = Runner.diagnose(stdout: out, stderr: err) {
            return .failure(reason: problem)
        }

        logToolOutput(stdout: out, stderr: err)

        return .success
    }

    private func adopt(_ task: Process) {
        let previous: Process?

        holdLock.lock()
        previous = holdProcess
        holdProcess = task
        holdExitReason = nil
        holdLock.unlock()

        if let previous, previous !== task {
            // Make before break: the replacement is already holding the point, so the
            // old session can go away without a gap on real GPS.
            DispatchQueue.global(qos: .userInitiated).async {
                previous.terminateNow()
            }
        }
    }

    private func handleTermination(of process: Process, outDrain: PipeDrain, errDrain: PipeDrain) {
        holdLock.lock()
        let wasHeld = holdProcess === process
        let deliberate = isStopping
        if wasHeld {
            holdProcess = nil
        }
        holdLock.unlock()

        guard wasHeld, !deliberate else { return }

        let status = process.terminationStatus
        let out = outDrain.text(timeout: 1)
        let err = errDrain.text(timeout: 1)

        let reason: String
        if status == 0 {
            reason = "The device session ended on its own, so the simulated location was released by the device."
        } else {
            reason = Runner.describeFailure(status: status, stdout: out, stderr: err)
        }

        holdLock.lock()
        holdExitReason = reason
        holdLock.unlock()

        log?("Device session ended: \(reason)")
    }

    private func logToolOutput(stdout: String, stderr: String) {
        let combined = [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        guard !combined.isEmpty else { return }
        log?("tool output: \(combined)")
    }

    /// Maps a failed invocation onto something the user can act on, without hiding
    /// the raw output.
    static func describeFailure(status: Int32, stdout: String, stderr: String) -> String {
        let raw = [stderr, stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        var message = hint(for: raw) ?? "The location tool exited with code \(status)."

        if !raw.isEmpty {
            message += "\n\n\(raw.suffix(1200))"
        }

        return message
    }

    /// Detects failures that a zero exit status hides (a Python traceback printed by
    /// a wrapper, an explicit ERROR line).
    static func diagnose(stdout: String, stderr: String) -> String? {
        let raw = [stderr, stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        guard !raw.isEmpty else { return nil }

        let markers = ["Traceback (most recent call last)", "ERROR:", "CRITICAL:", "error: ", "Exception:"]
        guard markers.contains(where: { raw.contains($0) }) else { return nil }

        var message = hint(for: raw) ?? "The location tool reported an error."
        message += "\n\n\(raw.suffix(1200))"
        return message
    }

    private static func hint(for raw: String) -> String? {
        if raw.contains("DeviceLocked") {
            return "The iPhone is locked. Unlock it (and keep it unlocked) so the simulated location can be applied."
        }

        if raw.contains("ConnectionRefusedError")
            || raw.contains("ConnectionAbortedError")
            || raw.contains("Errno 61")
            || raw.contains("Connection refused")
            || raw.contains("RemoteServiceDiscovery")
            || raw.contains("StartServiceError") {
            return "The iOS 17+ tunnel is gone. Restart it (`sudo pymobiledevice3 lockdown start-tunnel`) and paste the new RSD address and port."
        }

        if raw.contains("NoDeviceConnectedError")
            || raw.contains("no device found")
            || raw.contains("No device found")
            || raw.contains("MuxException")
            || raw.contains("ConnectionFailedError") {
            return "The iPhone is not reachable. Check the cable, unlock the device, and confirm the trust prompt."
        }

        if raw.contains("DeveloperDiskImage")
            || raw.contains("developer disk")
            || raw.contains("not mounted")
            || raw.contains("Developer mode") {
            return "The Developer Disk Image is not mounted (or Developer Mode is off). Mount it and try again."
        }

        if raw.contains("PasswordRequiredError") || raw.contains("Permission denied") {
            return "Permission denied. Some pymobiledevice3 commands require sudo, and the device must be trusted."
        }

        if raw.contains("adb: device") || raw.contains("device offline") || raw.contains("device unauthorized") {
            return "adb cannot reach the device. Reconnect it and accept the USB debugging prompt."
        }

        return nil
    }

    static func pymobiledeviceMissingMessage(pythonCheck: (isInstalled: Bool, version: String?)) -> String {
        var message = """
        pymobiledevice3 not found. Searched the following locations:
        • System PATH (using 'which' command)
        • /opt/homebrew/bin/
        • /usr/local/bin/
        • /Applications/anaconda3/bin/
        • ~/.local/bin/
        • ~/Library/Python/*/bin/

        """

        if !pythonCheck.isInstalled {
            message += """
            ⚠️ Python 3 is not installed!

            Install Python 3 first:
            brew install python3

            Then install pymobiledevice3:
            python3 -m pip install -U pymobiledevice3 --break-system-packages --user
            """
        } else {
            message += """
            Python version: \(pythonCheck.version ?? "unknown")

            Installation command:
            python3 -m pip install -U pymobiledevice3 --break-system-packages --user

            After installation, verify with: which pymobiledevice3
            """
        }

        return message
    }

    private func checkPythonInstallation() -> (isInstalled: Bool, version: String?) {
        let pythonCommands = ["python3", "python"]

        for command in pythonCommands {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            task.arguments = [command]

            guard let result = try? ProcessRunner.run(task, timeout: 5), result.terminationStatus == 0 else {
                continue
            }

            let versionTask = Process()
            versionTask.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            versionTask.arguments = [command, "--version"]

            let versionResult = try? ProcessRunner.run(versionTask, timeout: 5)
            let versionString = [versionResult?.stdoutText, versionResult?.stderrText]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty })

            return (true, versionString)
        }

        return (false, nil)
    }

    private func findPymobiledevice3Path() -> String? {
        let fileManager = FileManager.default

        // Strategy 1: Use 'which' to find pymobiledevice3 in PATH (fastest and most reliable)
        let whichTask = Process()
        whichTask.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichTask.arguments = ["pymobiledevice3"]

        if let result = try? ProcessRunner.run(whichTask, timeout: 5), result.terminationStatus == 0 {
            let pathString = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pathString.isEmpty && fileManager.fileExists(atPath: pathString) {
                return pathString
            }
        }

        // Strategy 2: Check common installation paths
        let commonPaths = [
            "/opt/homebrew/bin/pymobiledevice3",              // ARM64 homebrew
            "/usr/local/bin/pymobiledevice3",                 // Intel homebrew
            "/Applications/anaconda3/bin/pymobiledevice3",    // Anaconda
            "\(NSHomeDirectory())/.local/bin/pymobiledevice3" // pip user local
        ]

        for path in commonPaths {
            if fileManager.fileExists(atPath: path) {
                return path
            }
        }

        // Strategy 3: Search ~/Library/Python/*/bin/pymobiledevice3
        let libraryPath = "\(NSHomeDirectory())/Library/Python"

        guard fileManager.fileExists(atPath: libraryPath) else {
            return nil
        }

        do {
            let pythonVersions = try fileManager.contentsOfDirectory(atPath: libraryPath)
            let sortedVersions = pythonVersions.sorted().reversed() // Prefer newer versions

            for version in sortedVersions {
                let binPath = "\(libraryPath)/\(version)/bin/pymobiledevice3"
                if fileManager.fileExists(atPath: binPath) {
                    return binPath
                }
            }
        } catch {
            return nil
        }

        return nil
    }

    private func taskForAndroid(args: [String], adbPath: String) -> Process {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: adbPath)
        task.arguments = args

        return task
    }
}

extension CLLocationCoordinate2D {

    var description: String { "\(latitude) \(longitude)" }
}

extension Process {

    var logDescription: String {
        var description: String = ""
        if let executableURL {
            description += "\(executableURL.absoluteString) "
        }

        if let arguments {
            description += "\(arguments.joined(separator: " "))"
        }

        return description
    }
}
