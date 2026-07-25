// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Clickwheel",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        // Typed ScriptingBridge interface to Music.app, generated from its sdef.
        .target(
            name: "MusicBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("ScriptingBridge"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "Clickwheel",
            dependencies: ["MusicBridge"],
            // Metal sources are compiled by Scripts/build_app.sh, not SwiftPM.
            exclude: ["Shaders"],
            resources: [
                .copy("Resources/Clickwheel.metallib"),
                .process("Resources/en.lproj"),
                .process("Resources/es.lproj"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
