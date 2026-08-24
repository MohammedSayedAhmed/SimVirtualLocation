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
    static let useUserspace = "use_userspace_tunnel"
    static let keepLocationApplied = "keep_location_applied"
    static let keepAliveInterval = "keep_alive_interval"

    /// Whether route playback drives like a car rather than at a constant speed.
    static let realisticDriving = "realistic_driving"

    /// The point being held, so a crash or a restart resumes it.
    static let isHolding = "is_holding"
    static let heldLatitude = "held_latitude"
    static let heldLongitude = "held_longitude"

    /// The saved day plan, JSON-encoded.
    static let dayPlan = "day_plan"

    /// Whether a day plan was running, so a quit or a restart picks it back up.
    static let isRunningDayPlan = "is_running_day_plan"
}
