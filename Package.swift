// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Gaugeglass",
    products: [
        .library(name: "GaugeglassCore", targets: ["GaugeglassCore"]),
        .executable(name: "gaugeglass-inspect", targets: ["gaugeglass-inspect"])
    ],
    targets: [
        .target(name: "GaugeglassCore"),
        .executableTarget(name: "gaugeglass-inspect", dependencies: ["GaugeglassCore"]),
        .testTarget(name: "GaugeglassCoreTests", dependencies: ["GaugeglassCore"])
    ]
)
