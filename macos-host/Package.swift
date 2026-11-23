// swift-tools-version:5.9
//
// HaloLink macOS host — SwiftPM manifest.
//
// The package deliberately has zero external dependencies. Everything is built on
// Apple system frameworks only:
//   Foundation / AppKit / CoreGraphics / CoreMedia / CoreVideo / VideoToolbox /
//   ScreenCaptureKit / ImageIO / Network / ApplicationServices.
//
// Two targets:
//   - CVirtualDisplay: a tiny Objective-C wrapper around Apple's private
//     CGVirtualDisplay* classes (CoreGraphics). The classes are looked up purely
//     through the Objective-C runtime, so no private headers or symbols are needed.
//   - HaloLinkHost: the actual `halolink-host` executable.
//
import PackageDescription

let package = Package(
    name: "HaloLinkHost",
    platforms: [
        // ScreenCaptureKit display capture + CGVirtualDisplay private API are
        // available well before 14.0; 14.0 keeps the SCK surface we use stable.
        .macOS(.v14)
    ],
    products: [
        .executable(name: "halolink-host", targets: ["HaloLinkHost"])
    ],
    targets: [
        .target(
            name: "CVirtualDisplay",
            path: "Sources/CVirtualDisplay",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .executableTarget(
            name: "HaloLinkHost",
            dependencies: ["CVirtualDisplay"],
            path: "Sources/HaloLinkHost",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("ImageIO"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Network")
            ]
        )
    ],
    // Swift 5 language mode: this code base is GCD/callback oriented (ScreenCaptureKit,
    // VideoToolbox and Network.framework are all callback APIs); Swift 6 strict
    // concurrency would add noise without buying anything here.
    swiftLanguageVersions: [.v5]
)
