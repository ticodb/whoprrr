// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Whopper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Whopper", targets: ["Whopper"]),
        .executable(name: "ddcprobe", targets: ["ddcprobe"]),
        .executable(name: "audioprobe", targets: ["audioprobe"]),
        .executable(name: "windowprobe", targets: ["windowprobe"]),
        .executable(name: "logiprobe", targets: ["logiprobe"]),
        .executable(name: "inputprobe", targets: ["inputprobe"]),
        .executable(name: "clipprobe", targets: ["clipprobe"]),
    ],
    targets: [
        // Vendored m1ddc transport (MIT) behind a tiny C API. Private macOS calls stay in here.
        .target(
            name: "CDDC",
            path: "Sources/CDDC",
            exclude: ["upstream/PROVENANCE.md", "upstream/LICENSE-m1ddc"],
            publicHeadersPath: "include",
            // Upstream m1ddc is manual-retain-release Objective-C, built without ARC by its Makefile.
            cSettings: [.unsafeFlags(["-fno-objc-arc"])],
            linkerSettings: [.linkedFramework("CoreDisplay"), .linkedFramework("IOKit")]
        ),
        .target(name: "DisplayCore", dependencies: ["CDDC"], path: "Sources/DisplayCore"),
        .executableTarget(name: "ddcprobe", dependencies: ["DisplayCore"], path: "Sources/ddcprobe"),
        .target(name: "WhopperKit", path: "Sources/WhopperKit"),
        .target(name: "AudioCore", path: "Sources/AudioCore"),
        .target(name: "LogitechCore", path: "Sources/LogitechCore"),
        .executableTarget(name: "logiprobe", dependencies: ["LogitechCore"], path: "Sources/logiprobe"),
        .target(name: "InputCore", dependencies: ["WhopperKit"], path: "Sources/InputCore"),
        .target(name: "ClipboardCore", dependencies: ["WhopperKit"], path: "Sources/ClipboardCore",
                linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "WindowCore", dependencies: ["WhopperKit"], path: "Sources/WindowCore"),
        .executableTarget(name: "clipprobe", dependencies: ["ClipboardCore"], path: "Sources/clipprobe"),
        .executableTarget(name: "inputprobe", dependencies: ["InputCore"], path: "Sources/inputprobe"),
        .executableTarget(name: "windowprobe", dependencies: ["WindowCore"], path: "Sources/windowprobe"),
        .executableTarget(name: "audioprobe", dependencies: ["AudioCore"], path: "Sources/audioprobe"),
        .executableTarget(name: "Whopper", dependencies: ["DisplayCore", "WhopperKit", "AudioCore", "WindowCore", "ClipboardCore", "InputCore", "LogitechCore"], path: "Sources/Whopper"),
        .testTarget(name: "DisplayCoreTests", dependencies: ["DisplayCore"], path: "Tests/DisplayCoreTests"),
        .testTarget(name: "AudioCoreTests", dependencies: ["AudioCore"], path: "Tests/AudioCoreTests"),
        .testTarget(name: "WindowCoreTests", dependencies: ["WindowCore"], path: "Tests/WindowCoreTests"),
        .testTarget(name: "ClipboardCoreTests", dependencies: ["ClipboardCore"], path: "Tests/ClipboardCoreTests"),
        .testTarget(name: "InputCoreTests", dependencies: ["InputCore"], path: "Tests/InputCoreTests"),
        .testTarget(name: "LogitechCoreTests", dependencies: ["LogitechCore"], path: "Tests/LogitechCoreTests"),
        .testTarget(name: "WhopperKitTests", dependencies: ["WhopperKit"], path: "Tests/WhopperKitTests"),
    ],
    swiftLanguageModes: [.v5]
)
