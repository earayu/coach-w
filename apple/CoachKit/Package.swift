// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoachKit",
    platforms: [.iOS(.v18), .watchOS(.v11), .macOS(.v15)],
    products: [
        .library(name: "CoachKit", targets: ["CoachKit"]),
    ],
    targets: [
        .target(name: "CoachKit"),
        .testTarget(name: "CoachKitTests", dependencies: ["CoachKit"]),
    ]
)
