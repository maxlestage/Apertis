// swift-tools-version:5.10
import PackageDescription

// Cœur d'Apertis : modèles, colorimétrie de référence, format de projet et timeline.
// Ne dépend que de Foundation : compilable et testable hors d'iOS (CI, Linux, macOS).
let package = Package(
    name: "ApertisCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ApertisCore", targets: ["ApertisCore"]),
    ],
    targets: [
        .target(name: "ApertisCore"),
        .testTarget(name: "ApertisCoreTests", dependencies: ["ApertisCore"]),
    ]
)
