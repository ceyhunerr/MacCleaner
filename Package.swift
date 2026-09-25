// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacCleaner",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MacCleaner", path: "Sources/MacCleaner")
    ]
)
