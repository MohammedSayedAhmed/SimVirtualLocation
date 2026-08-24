import CoreLocation
import Foundation

/// Turns a route into a drive that behaves like a car rather than a cursor.
///
/// Playback is driven entirely by the timestamps in the GPX file — `play` sleeps for the
/// gap between two points — so "drive realistically" is not a change to how the location
/// is pushed. It is a change to how those timestamps are spaced. A constant speed spaces
/// them evenly, which is what reads as fake: real cars accelerate, brake for corners, sit
/// at lights and crawl in traffic.
///
/// The model here is the standard one for generating a feasible speed profile along a
/// path: work out the fastest you are allowed to go at each point, then make the result
/// physically reachable by limiting how fast speed can rise and fall.
///
///   1. A ceiling per point — the lowest of the cruising speed, what the corner radius
///      allows at a comfortable lateral acceleration, and zero wherever the car stops.
///   2. A forward pass, which stops the car accelerating harder than an engine can.
///   3. A backward pass, which stops it braking harder than a driver would.
///   4. Integration to get an arrival time for every point, plus the seconds spent
///      standing still at each stop.
///
/// Everything random is drawn from a seeded generator, so the same route drives the same
/// way twice. Re-planning after a pause would otherwise reshuffle every light.
enum DriveProfile {

    /// One point of the finished drive, and how long after the start it is reached.
    struct Sample {
        let coordinate: CLLocationCoordinate2D
        let offset: TimeInterval
    }

    struct Settings {
        /// The speed aimed for where the road allows it, in metres per second.
        var cruiseSpeed: CLLocationSpeed

        /// Stop at junctions and lights. Off gives smooth driving that still slows for
        /// corners — closer to an empty road at night than to rush hour.
        var stops: Bool = true

        /// Anything drawn at random comes from here, so a route is reproducible.
        var seed: UInt64 = 0x5D8E'7C31'A2B4'96F1
    }

    // MARK: - Physical constants
    //
    // Chosen to feel like an ordinary car driven unhurriedly, not to match any particular
    // vehicle. They are the difference between movement that reads as driving and
    // movement that reads as a dot being dragged.

    /// Comfortable acceleration. About 0 to 50 km/h in eight seconds.
    private static let acceleration: Double = 1.8

    /// Comfortable braking. Firmer than accelerating, as real braking is.
    private static let braking: Double = 2.5

    /// Lateral acceleration tolerated in a corner. Above roughly this, passengers lean.
    /// This is what makes the car slow for bends without being told where they are.
    private static let corneringForce: Double = 2.2

    /// Distance between generated points. Fine enough that corners resolve, coarse
    /// enough that an hour of driving is not a million points.
    private static let spacing: CLLocationDistance = 6

    /// Heading change across a window this wide is what identifies a corner.
    private static let cornerWindow: CLLocationDistance = 30

    /// Turn sharper than this counts as a junction rather than a bend in the road.
    private static let junctionAngle: Double = 45 * .pi / 180

    /// How long the car sits at a light, in seconds.
    private static let stopDwell: ClosedRange<TimeInterval> = 8...50

    /// Junctions are not all lights, and lights are not always red.
    private static let junctionStopChance: Double = 0.45

    /// Roughly how far apart lights are on a road that has them.
    private static let lightSpacing: ClosedRange<CLLocationDistance> = 250...900

    /// Above this cruising speed the road is treated as open — no lights placed.
    private static let urbanSpeedCeiling: CLLocationSpeed = 22  // ~80 km/h

    /// Never stretch or squash a drive beyond this, however odd the target duration.
    private static let scaleLimits: ClosedRange<Double> = 0.35...5.0

    /// Build the drive.
    ///
    /// - Parameter targetDuration: when set, the finished profile is stretched or
    ///   squashed to take exactly this long. This is how live traffic gets in: the
    ///   routing service's own estimate already accounts for it, so matching that
    ///   estimate reproduces today's conditions without needing a traffic feed of our
    ///   own. It is also how a planned day keeps its arrival times.
    static func build(
        path: [CLLocationCoordinate2D],
        settings: Settings,
        targetDuration: TimeInterval? = nil
    ) -> [Sample] {
        guard path.count > 1 else {
            return path.map { Sample(coordinate: $0, offset: 0) }
        }

        let points = resample(path, spacing: spacing)
        guard points.count > 2 else {
            return points.enumerated().map { Sample(coordinate: $1, offset: Double($0)) }
        }

        var rng = SeededGenerator(seed: settings.seed)
        let cruise = max(settings.cruiseSpeed, 1.0)

        let ceilings = speedCeilings(points, cruise: cruise)
        var stopIndices: Set<Int> = []
        var dwell: [Int: TimeInterval] = [:]

        if settings.stops {
            stopIndices = chooseStops(points, ceilings: ceilings, cruise: cruise, rng: &rng)
            for index in stopIndices {
                dwell[index] = TimeInterval.random(in: stopDwell, using: &rng)
            }
        }

        let speeds = feasibleSpeeds(ceilings: ceilings, stops: stopIndices)
        var samples = integrate(points: points, speeds: speeds, dwell: dwell)

        if let targetDuration, let last = samples.last?.offset, last > 0 {
            let scale = min(max(targetDuration / last, scaleLimits.lowerBound), scaleLimits.upperBound)
            if abs(scale - 1) > 0.01 {
                samples = samples.map { Sample(coordinate: $0.coordinate, offset: $0.offset * scale) }
            }
        }

        return samples
    }

    // MARK: - Steps

    /// The fastest the car is allowed to go at each point, before physics.
    private static func speedCeilings(_ points: [CLLocationCoordinate2D], cruise: CLLocationSpeed) -> [CLLocationSpeed] {
        let window = max(2, Int(cornerWindow / spacing))
        var ceilings = [CLLocationSpeed](repeating: cruise, count: points.count)

        for index in points.indices {
            let back = max(0, index - window)
            let forward = min(points.count - 1, index + window)
            guard forward - back >= 2 else { continue }

            let turn = abs(angleBetween(
                bearing(points[back], points[min(back + 1, forward)]),
                bearing(points[max(forward - 1, back)], points[forward])
            ))
            guard turn > 0.02 else { continue }

            // A turn of `turn` radians taken over this much road implies a radius, and a
            // radius implies the speed at which cornering stops being comfortable.
            let arc = Double(forward - back) * spacing
            let radius = arc / turn
            ceilings[index] = min(cruise, (corneringForce * radius).squareRoot())
        }

        return ceilings
    }

    /// Where the car comes to a complete stop: junctions it has to give way at, and
    /// lights spaced along roads slow enough to have them.
    private static func chooseStops(
        _ points: [CLLocationCoordinate2D],
        ceilings: [CLLocationSpeed],
        cruise: CLLocationSpeed,
        rng: inout SeededGenerator
    ) -> Set<Int> {
        var stops: Set<Int> = []
        let window = max(2, Int(cornerWindow / spacing))

        // Junctions: a sharp change of direction is somewhere you had to slow anyway.
        var index = window
        while index < points.count - window {
            let turn = abs(angleBetween(
                bearing(points[index - window], points[index - window + 1]),
                bearing(points[index + window - 1], points[index + window])
            ))
            if turn > junctionAngle, Double.random(in: 0...1, using: &rng) < junctionStopChance {
                stops.insert(index)
                index += window * 3
                continue
            }
            index += 1
        }

        // Lights, on roads slow enough to have them. A motorway gets none.
        if cruise <= urbanSpeedCeiling {
            var travelled = CLLocationDistance.random(in: lightSpacing, using: &rng)
            while Int(travelled / spacing) < points.count - window {
                let at = Int(travelled / spacing)
                // Not on top of a corner, where the car is already crawling.
                if ceilings[at] > cruise * 0.5, !stops.contains(where: { abs($0 - at) < window * 2 }) {
                    stops.insert(at)
                }
                travelled += CLLocationDistance.random(in: lightSpacing, using: &rng)
            }
        }

        return stops
    }

    /// Make the ceiling reachable: no acceleration or braking harder than a car does.
    private static func feasibleSpeeds(ceilings: [CLLocationSpeed], stops: Set<Int>) -> [CLLocationSpeed] {
        var speeds = ceilings
        for index in stops where speeds.indices.contains(index) {
            speeds[index] = 0
        }

        // Starting from rest, and never gaining speed faster than the engine allows.
        speeds[0] = 0
        for index in 1..<speeds.count {
            let reachable = (speeds[index - 1] * speeds[index - 1] + 2 * acceleration * spacing).squareRoot()
            speeds[index] = min(speeds[index], reachable)
        }

        // Backwards, so the car is already slowing before it needs to be stopped.
        speeds[speeds.count - 1] = 0
        for index in stride(from: speeds.count - 2, through: 0, by: -1) {
            let reachable = (speeds[index + 1] * speeds[index + 1] + 2 * braking * spacing).squareRoot()
            speeds[index] = min(speeds[index], reachable)
        }

        return speeds
    }

    /// Turn speeds into arrival times.
    private static func integrate(
        points: [CLLocationCoordinate2D],
        speeds: [CLLocationSpeed],
        dwell: [Int: TimeInterval]
    ) -> [Sample] {
        var samples: [Sample] = []
        samples.reserveCapacity(points.count)

        var clock: TimeInterval = 0
        for index in points.indices {
            samples.append(Sample(coordinate: points[index], offset: clock))

            if let wait = dwell[index] {
                clock += wait
                // Emit the stop again at its end, so playback actually sits there rather
                // than teleporting past a point it was supposed to wait at.
                samples.append(Sample(coordinate: points[index], offset: clock))
            }

            guard index < points.count - 1 else { break }

            // Average speed across the step. Guarded, because both ends are zero at a
            // standstill and dividing by that is how a drive becomes infinitely long.
            let mean = (speeds[index] + speeds[index + 1]) / 2
            clock += spacing / max(mean, 0.35)
        }

        return samples
    }

    // MARK: - Geometry

    private static func resample(
        _ path: [CLLocationCoordinate2D],
        spacing: CLLocationDistance
    ) -> [CLLocationCoordinate2D] {
        var cumulative: [CLLocationDistance] = [0]
        for index in 1..<path.count {
            cumulative.append(cumulative[index - 1] + CLLocation.distance(from: path[index - 1], to: path[index]))
        }
        guard let total = cumulative.last, total > spacing else { return path }

        var result: [CLLocationCoordinate2D] = []
        result.reserveCapacity(Int(total / spacing) + 2)

        var travelled: CLLocationDistance = 0
        var segment = 0
        while travelled < total {
            while segment < cumulative.count - 2, cumulative[segment + 1] < travelled { segment += 1 }
            let start = cumulative[segment]
            let span = cumulative[segment + 1] - start
            let fraction = span > 0 ? (travelled - start) / span : 0
            let from = path[segment]
            let to = path[segment + 1]
            result.append(
                CLLocationCoordinate2D(
                    latitude: from.latitude + (to.latitude - from.latitude) * fraction,
                    longitude: from.longitude + (to.longitude - from.longitude) * fraction
                )
            )
            travelled += spacing
        }
        if let last = path.last { result.append(last) }
        return result
    }

    private static func bearing(_ from: CLLocationCoordinate2D, _ to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let deltaLon = (to.longitude - from.longitude) * .pi / 180
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        return atan2(y, x)
    }

    /// Signed difference between two bearings, wrapped into -pi...pi.
    private static func angleBetween(_ a: Double, _ b: Double) -> Double {
        var delta = b - a
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        return delta
    }

    /// Small deterministic generator, so a route drives the same way every time.
    struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed == 0 ? 0x9E37'79B9'7F4A'7C15 : seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37'79B9'7F4A'7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58'476D'1CE4'E5B9
            z = (z ^ (z >> 27)) &* 0x94D0'49BB'1331'11EB
            return z ^ (z >> 31)
        }
    }
}
