// swift-tools-version: 5.9
// The Swift Package Manager form of this plugin. The CocoaPods form is
// `../wxscan_live.podspec`, which builds the same sources from the same place;
// both are kept until CocoaPods goes read-only.
//
// Nothing native is built here either way. The scanner is a Dart code asset,
// produced by the wxscan package's build hook and bundled by Flutter; the
// Swift side resolves its entry points with dlsym (see WxScanNative.swift).
import PackageDescription

let package = Package(
    name: "wxscan_live",
    platforms: [
        .macOS("10.15")
    ],
    products: [
        // Hyphenated: Swift Package Manager uses a library's name as the
        // CFBundleIdentifier when it links dynamically, and that cannot hold
        // an underscore. Flutter's tooling looks for exactly this name.
        .library(name: "wxscan-live", targets: ["wxscan_live"])
    ],
    dependencies: [
        // Flutter itself, as the tooling lays it out for a Swift Package
        // Manager build. The path is into the application's ephemeral
        // directory, which is why it exists only at build time.
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        // Header only, for the result structs the scanner hands back.
        .target(name: "wxscan_c"),
        .target(
            name: "wxscan_live",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                "wxscan_c"
            ]
        )
    ]
)
