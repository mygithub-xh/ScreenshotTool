// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenshotTool",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ScreenshotTool", targets: ["ScreenshotTool"])
    ],
    targets: [
        .executableTarget(
            name: "ScreenshotTool",
            exclude: ["Info.plist", "Entitlements.plist", "AppIcon.icns"]
        )
    ]
)
