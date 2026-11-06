// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetingScribe", platforms: [.macOS("14.2")],
    products: [.library(name: "MeetingCore", targets: ["MeetingCore"]), .executable(name: "MeetingScribe", targets: ["MeetingScribe"])],
    targets: [.target(name: "MeetingCore"), .executableTarget(name: "MeetingScribe", dependencies: ["MeetingCore"]), .testTarget(name: "MeetingCoreTests", dependencies: ["MeetingCore"])],
    swiftLanguageVersions: [.v5]
)
