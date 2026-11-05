// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "openedbot-notch",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "OpenedbotPopup",
            path: "Sources/OpenedbotPopup",
            resources: [.copy("../../Resources/bots"), .copy("../../Resources/faces"), .copy("../../Resources/brand-marks.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OpenedbotPopupTests",
            dependencies: ["OpenedbotPopup"],
            path: "Tests/OpenedbotPopupTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
