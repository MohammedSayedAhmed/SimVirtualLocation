// swift-tools-version: 5.9

// A test harness for the app's pure logic, deliberately NOT an Xcode test target.
//
// The .xcodeproj in this repo is maintained by hand, and a unit-test target means
// project and scheme surgery with real odds of breaking the app build for the sake
// of scaffolding. This package sidesteps all of it: it compiles just the pure files
// below — schedule arithmetic, the drive profile, polyline geometry, GPX writing —
// plus the tests, and `swift test` runs them without touching the app project.
//
// A file belongs in `sources` only if it imports nothing beyond Foundation and
// CoreLocation. The app target compiles the same files, so what the tests exercise
// is what ships.
import PackageDescription

let package = Package(
    name: "SimVLLogic",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "SimVLLogic",
            path: "SimVirtualLocation",
            sources: [
                "Models/Coordinate.swift",
                "Models/LogEntry.swift",
                "Models/LogBuffer.swift",
                "Models/DayPlan.swift",
                "Logic/DayPlanRunner.swift",
                "Utilities/CoordinateParsing.swift",
                "Utilities/Polyline.swift",
                "Utilities/DriveProfile.swift",
                "Utilities/GPXRoute.swift",
            ]
        ),
        .testTarget(
            name: "LogicTests",
            dependencies: ["SimVLLogic"],
            path: "Tests/LogicTests"
        ),
    ]
)
