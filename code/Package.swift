// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AutoMeetingRecorder", platforms: [.macOS("14.2")],
    products: [.library(name: "MeetingCore", targets: ["MeetingCore"]), .executable(name: "AutoMeetingRecorder", targets: ["AutoMeetingRecorder"])],
    targets: [.target(name: "MeetingCore"), .executableTarget(name: "AutoMeetingRecorder", dependencies: ["MeetingCore"]), .testTarget(name: "MeetingCoreTests", dependencies: ["MeetingCore"])],
    swiftLanguageVersions: [.v5]
)
