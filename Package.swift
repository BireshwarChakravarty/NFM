// swift-tools-version:5.9
import Foundation
import PackageDescription

// NFM targets Apple silicon Macs on macOS 27 and later. CI also builds a test
// copy with NFM_MACOS_MIN=26.0 so it can launch it on macOS 26 build machines.
let minimumMacOS = ProcessInfo.processInfo.environment["NFM_MACOS_MIN"] ?? "27.0"

let package = Package(
    name: "NFM",
    platforms: [.macOS(minimumMacOS)],
    products: [
        .executable(name: "NFM", targets: ["NFM"])
    ],
    targets: [
        .executableTarget(
            name: "NFM",
            path: "Sources/NFM",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("MediaPlayer"),
                .linkedFramework("IOKit"),
                .linkedFramework("SwiftUI"),
            ]
        )
    ]
)
