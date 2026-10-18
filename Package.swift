// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RecipeVault",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FujiCore", targets: ["FujiCore"]),
        .executable(name: "RecipeVault", targets: ["RecipeVault"])
    ],
    targets: [
        .target(name: "FujiCore"),
        .executableTarget(name: "RecipeVault", dependencies: ["FujiCore"], linkerSettings: [
            .linkedFramework("SwiftUI"), .linkedFramework("ImageCaptureCore"), .linkedFramework("Vision")
        ]),
        .testTarget(name: "FujiCoreTests", dependencies: ["FujiCore"]),
        .testTarget(name: "RecipeCameraTests", dependencies: ["FujiCore", "RecipeVault"])
    ]
)
