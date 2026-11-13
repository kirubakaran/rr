// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "rr",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything except EventKit: intent, recurrence engine, preview, model call.
        .target(name: "RRCore"),
        .executableTarget(
            name: "rr",
            dependencies: ["RRCore"],
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embeds the Reminders usage strings macOS requires for the permission prompt.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist", "-Xlinker", "Sources/rr/Info.plist",
                ])
            ]
        ),
        .testTarget(name: "RRCoreTests", dependencies: ["RRCore", "rr"]),
    ]
)
