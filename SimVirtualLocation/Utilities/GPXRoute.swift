import CoreLocation
import Foundation

/// Builds a timestamped GPX track for `pymobiledevice3 developer dvt simulate-location play`.
///
/// `play` walks the whole file inside a single DVT session, sleeping between points according
/// to their timestamps. Emitting points at a fixed cadence and spacing the timestamps to match
/// the requested speed reproduces the movement without spawning a child process per waypoint.
enum GPXRoute {

    enum Failure: LocalizedError {
        case emptyRoute
        case writeFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .emptyRoute:
                return "Route has no points to simulate."
            case .writeFailed(let underlying):
                return "Could not write the route file: \(underlying.localizedDescription)"
            }
        }
    }

    /// Seconds between emitted track points. `play` sleeps for the gap between timestamps, so
    /// this is the granularity of the simulated movement.
    static let sampleInterval: TimeInterval = 1.0

    /// How far apart the points of a stationary hold are timestamped. `play` sleeps for
    /// the gap, so this is how often the point is re-asserted inside the session.
    static let holdInterval: TimeInterval = 10

    /// How long a stationary hold file covers before `play` runs out of points. The hold
    /// is restarted when that happens, so this only sets how rarely that restart occurs.
    static let holdDuration: TimeInterval = 12 * 60 * 60

    /// Write a GPX that stands still at `coordinate`.
    ///
    /// A `simulate-location set` process owns the point only while it lives — when it goes
    /// the device reverts to real GPS, which is why setting a point once, or setting it
    /// over and over, both fail. `play` instead walks a file inside a single DVT session
    /// that stays open, so a file full of the same point holds that point without ever
    /// closing the channel.
    static func writeStationary(
        coordinate: CLLocationCoordinate2D,
        interval: TimeInterval = holdInterval,
        duration: TimeInterval = holdDuration
    ) throws -> URL {
        let count = max(2, Int(duration / max(interval, 1)))
        return try write(
            points: Array(repeating: coordinate, count: count),
            interval: interval,
            name: "stationary hold"
        )
    }

    /// Resample `coordinates` at a constant `speed` (metres per second) and write a GPX file
    /// into the temporary directory.
    static func write(coordinates: [CLLocationCoordinate2D], speed: CLLocationSpeed) throws -> URL {
        // One point per sampleInterval of travel at this speed.
        let points = Polyline.resample(coordinates, step: max(speed, 0.1) * sampleInterval)
        return try write(points: points, interval: sampleInterval, name: "simulated route")
    }

    /// Write a drive whose points carry their own arrival times.
    ///
    /// Constant-speed playback spaces timestamps evenly. A real car does not move that
    /// way, so a realistic drive arrives here with the spacing already decided — braking
    /// into corners, waiting at lights — and this only has to write it out.
    static func write(samples: [DriveProfile.Sample]) throws -> URL {
        try write(
            stamps: samples.map { ($0.coordinate, $0.offset) },
            name: "realistic drive"
        )
    }

    private static func write(
        points: [CLLocationCoordinate2D],
        interval: TimeInterval,
        name: String
    ) throws -> URL {
        try write(
            stamps: points.enumerated().map { ($0.element, Double($0.offset) * interval) },
            name: name
        )
    }

    private static func write(
        stamps: [(CLLocationCoordinate2D, TimeInterval)],
        name: String
    ) throws -> URL {
        guard !stamps.isEmpty else { throw Failure.emptyRoute }

        let formatter = ISO8601DateFormatter()
        // Fractional, because a realistic drive spaces points a few tenths of a second
        // apart. Whole seconds collapsed runs of points onto one timestamp, so `play`
        // injected them as a burst and slept a full second — 1 Hz movement, not a drive.
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = Date()

        var gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="SimVirtualLocation" xmlns="http://www.topografix.com/GPX/1/1">
          <trk><name>\(name)</name><trkseg>

        """

        for (point, offset) in stamps {
            let stamp = formatter.string(from: start.addingTimeInterval(offset))
            gpx += "    <trkpt lat=\"\(point.latitude)\" lon=\"\(point.longitude)\"><time>\(stamp)</time></trkpt>\n"
        }

        gpx += """
          </trkseg></trk>
        </gpx>

        """

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("simvirtuallocation-\(filePrefix)\(UUID().uuidString).gpx")

        do {
            try gpx.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw Failure.writeFailed(underlying: error)
        }

        // One playback session exists at a time, so one file is live at a time: the
        // previous one's process is already stopped (or being stopped) by whoever asked
        // for this write, and `play` reads the whole file when it starts anyway. Nothing
        // deleted these before, and a day of holds and legs left hundreds behind.
        if let retired = lastWritten, retired != url {
            try? FileManager.default.removeItem(at: retired)
        }
        lastWritten = url

        return url
    }

    /// The most recent file handed out, deleted when the next one replaces it.
    /// Main-thread only, like every caller.
    private static var lastWritten: URL?

    /// Distinguishes this app instance's files from a previous run's, so the launch
    /// sweep can tell leftovers from files it just wrote itself.
    private static let filePrefix = String(UUID().uuidString.prefix(8)) + "-"

    /// Deletes GPX files left in the temporary directory by earlier runs.
    ///
    /// A crash or force-quit skips the replace-time delete above, and the last file of
    /// any session is never replaced at all. Called once at launch; a file belonging to
    /// a still-running helper is safe to unlink, since `play` parses the whole file
    /// before its first waypoint.
    static func removeLeftovers() {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }

        for name in names
        where name.hasPrefix("simvirtuallocation-") && name.hasSuffix(".gpx") && !name.contains(filePrefix) {
            try? manager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

}
