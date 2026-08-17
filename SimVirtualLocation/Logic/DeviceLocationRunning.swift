import CoreLocation
import Foundation

/// Abstraction over simulator / USB iOS / RSD iOS / Android injection for tests and composition.
///
/// Every injection reports an `InjectionOutcome` instead of failing silently: the
/// supervisor above this protocol can only keep a point applied if it is told when an
/// attempt did not work.
protocol DeviceLocationRunning: IOSProcessLaunching {
    var timeDelay: TimeInterval { get set }
    var log: ((String) -> Void)? { get set }
    var pymobiledevicePath: String? { get set }

    /// `true` while a long-lived helper process is holding a device session open.
    var isHoldingSession: Bool { get }

    /// Why the last long-lived session ended by itself, if it did. Reading clears it.
    func consumeHoldFailureReason() -> String?

    func stop()

    func runOnSimulator(
        location: CLLocationCoordinate2D,
        selectedSimulator: String,
        bootedSimulators: [Simulator]
    ) async -> InjectionOutcome

    func runOnIos(location: CLLocationCoordinate2D) async -> InjectionOutcome

    func runOnNewIos(
        location: CLLocationCoordinate2D,
        rsdAddress: String,
        rsdPort: String
    ) async -> InjectionOutcome

    func runOnAndroid(
        location: CLLocationCoordinate2D,
        adbDeviceId: String,
        adbPath: String,
        isEmulator: Bool
    ) async -> InjectionOutcome

    func resetIos(showAlert: @escaping (String) -> Void)
    func resetNewIos(rsdAddress: String, rsdPort: String, showAlert: @escaping (String) -> Void)
    func resetAndroid(adbDeviceId: String, adbPath: String, showAlert: @escaping (String) -> Void)
}

extension Runner: DeviceLocationRunning {}
