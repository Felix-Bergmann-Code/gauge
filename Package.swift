// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Gauge",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Gauge",
            path: "Sources/Gauge",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
