import Foundation

/// Centralized `UserDefaults` keys (keep legacy string values for migration).
enum AppStorageKey {
    static let savedLocations = "saved_locations"
    static let xcodePath = "xcode_path"
    /// Legacy name — stores `AppPlatform.rawValue`.
    static let platform = "device_type"
    static let adbPath = "adb_path"
    static let adbDeviceId = "adb_device_id"
    static let isEmulator = "is_emulator"

    /// Stores `DeviceMode.rawValue`.
    static let deviceMode = "device_mode"
    static let useRSD = "use_rsd"
    static let rsdAddress = "rsd_address"
    static let rsdPort = "rsd_port"
    static let selectedSimulator = "selected_simulator"
    static let selectedDevice = "selected_device"

    static let keepAliveEnabled = "keep_alive_enabled"
    static let keepAliveInterval = "keep_alive_interval"
}
