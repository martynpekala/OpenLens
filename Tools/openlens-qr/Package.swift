// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "openlens-qr",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "openlens-qr",
            path: "Sources"
        ),
    ]
)
