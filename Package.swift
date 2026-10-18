// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "DaikinACMenubar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DaikinACMenubar", targets: ["DaikinACMenubar"])],
    targets: [
        .executableTarget(name: "DaikinACMenubar")
    ]
)
