// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "DaikinACMenubar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DaikinACMenubar", targets: ["DaikinACMenubar"])],
    dependencies: [
        // Big-integer math for Cognito USER_SRP_AUTH. Pinned exactly; see THIRD_PARTY_NOTICES.md.
        .package(url: "https://github.com/attaswift/BigInt.git", exact: "5.7.0"),
    ],
    targets: [
        .executableTarget(name: "DaikinACMenubar", dependencies: [.product(name: "BigInt", package: "BigInt")])
    ]
)
