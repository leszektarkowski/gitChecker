// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitCheckerBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "GitCheckerBar")
    ]
)
