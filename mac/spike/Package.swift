// swift-tools-version: 6.0
import PackageDescription

// Phase 0 feasibility spike. Throwaway by design — the product code lives in
// mac/DisplayShare, mac/vd_helper and mac/DisplayShareCore. This package exists
// only to answer the go/no-go questions in Tasks 0.1 - 0.3.
let package = Package(
    name: "VDSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CGVirtualDisplayPrivate",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        .executableTarget(
            name: "vdspike",
            dependencies: ["CGVirtualDisplayPrivate"],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("AppKit"),
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreImage"),
            ]
        ),
    ]
)
