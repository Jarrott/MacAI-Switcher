// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AISwitcher",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AISwitcher", targets: ["AISwitcher"])
    ],
    targets: [
        .executableTarget(
            name: "AISwitcher",
            path: "Sources/AISwitcher",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "AISwitcherTests",
            dependencies: ["AISwitcher"],
            path: "Tests/AISwitcherTests"
        ),
    ]
)
