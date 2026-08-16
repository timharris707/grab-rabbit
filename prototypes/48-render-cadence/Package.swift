// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RenderCadencePrototype",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "cadence-probe", targets: ["CadenceProbe"]),
        .executable(name: "live-cadence-probe", targets: ["LiveCadenceProbe"]),
    ],
    targets: [
        .executableTarget(name: "CadenceProbe"),
        .target(name: "LiveProbeCore"),
        .executableTarget(name: "LiveCadenceProbe", dependencies: ["LiveProbeCore"]),
        .testTarget(name: "LiveProbeCoreTests", dependencies: ["LiveProbeCore"]),
    ],
    swiftLanguageModes: [.v5]
)
