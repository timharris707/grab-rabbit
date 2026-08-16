// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RenderCadencePrototype",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "cadence-probe", targets: ["CadenceProbe"]),
    ],
    targets: [
        .executableTarget(name: "CadenceProbe"),
    ],
    swiftLanguageModes: [.v5]
)
