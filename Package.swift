// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PomodoroTimer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "PomodoroTimer", path: "Sources/PomodoroTimer"),
        .testTarget(name: "PomodoroTimerTests", dependencies: ["PomodoroTimer"], path: "Tests/PomodoroTimerTests"),
    ]
)
