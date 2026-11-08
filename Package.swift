// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Filmback",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FujiCore", targets: ["FujiCore"]),
        .executable(name: "Filmback", targets: ["Filmback"])
    ],
    targets: [
        .target(name: "FujiCore"),
        .executableTarget(name: "Filmback", dependencies: ["FujiCore"], linkerSettings: [
            .linkedFramework("SwiftUI"), .linkedFramework("ImageCaptureCore"), .linkedFramework("Vision")
        ]),
        .testTarget(name: "FujiCoreTests", dependencies: ["FujiCore"]),
        .testTarget(name: "RecipeCameraTests", dependencies: ["FujiCore", "Filmback"])
    ]
)
