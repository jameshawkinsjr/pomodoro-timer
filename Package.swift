// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PomodoroTimer",
    platforms: [.macOS(.v13)],
    targets: [
        // Finding and verifying updates, without AppKit, so `swift test` can cover it.
        .target(name: "PomodoroTimerCore", path: "Sources/PomodoroTimerCore"),
        .executableTarget(name: "PomodoroTimer", dependencies: ["PomodoroTimerCore"], path: "Sources/PomodoroTimer"),
        .testTarget(name: "PomodoroTimerTests", dependencies: ["PomodoroTimer"], path: "Tests/PomodoroTimerTests"),
        .testTarget(name: "PomodoroTimerCoreTests", dependencies: ["PomodoroTimerCore"], path: "Tests/PomodoroTimerCoreTests"),
    ]
)
