// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NukeReplay",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "NukeReplay", targets: ["NukeReplay"])
    ],
    targets: [
        .target(name: "NukeReplay"),
        .testTarget(name: "NukeReplayTests", dependencies: ["NukeReplay"])
    ]
)
