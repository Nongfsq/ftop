// swift-tools-version: 6.0
import PackageDescription

// Allowed imports: FtopCore is Foundation-only; FtopSensors is the only target that touches
// system APIs (through CFtopSys for the private ones); FtopUI never imports FtopSensors.
let package = Package(
    name: "ftop",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "CFtopSys",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation"), .linkedLibrary("IOReport")]
        ),
        .target(name: "FtopCore"),
        .target(name: "FtopSensors", dependencies: ["FtopCore", "CFtopSys"]),
        .target(name: "FtopUI", dependencies: ["FtopCore"]),
        .executableTarget(name: "FtopApp", dependencies: ["FtopCore", "FtopSensors", "FtopUI"]),
        .executableTarget(name: "ftop", dependencies: ["FtopCore", "FtopSensors"]),
        .executableTarget(name: "ftop-helper"),
        .testTarget(name: "FtopCoreTests", dependencies: ["FtopCore"]),
        .testTarget(name: "FtopUITests", dependencies: ["FtopCore", "FtopUI"]),
    ],
    swiftLanguageModes: [.v6]
)
