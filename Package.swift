// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "kvm-display-sync",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "kvm-display-sync",
            path: "Sources/kvm-display-sync",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
            ]
        )
    ]
)
