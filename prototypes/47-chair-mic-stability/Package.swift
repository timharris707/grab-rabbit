// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ForegroundStabilityPrototype",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "foreground-probe", targets: ["ForegroundProbe"]),
    ],
    targets: [
        .executableTarget(name: "ForegroundProbe"),
    ],
    swiftLanguageModes: [.v5]
)
