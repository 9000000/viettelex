// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TelexCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "TelexCore", targets: ["TelexCore"]),
        .executable(name: "gen-lessons", targets: ["GenLessons"]),
        .executable(name: "gen-english", targets: ["GenEnglish"]),
        .executable(name: "gen-golden", targets: ["GenGolden"])
    ],
    targets: [
        .target(
            name: "TelexCore",
            // Bàn phím iOS (Release) build -Osize như phần còn lại của extension (iOS/project.yml)
            // — Xcode KHÔNG truyền SWIFT_OPTIMIZATION_LEVEL của project xuống package (trước:
            // -O). Chỉ iOS: macOS/Linux giữ -O như cũ. Package local (path:) nên unsafeFlags hợp lệ.
            swiftSettings: [.unsafeFlags(["-Osize"], .when(platforms: [.iOS], configuration: .release))]
        ),
        .executableTarget(
            name: "GenLessons",
            dependencies: ["TelexCore"]
        ),
        .executableTarget(
            name: "GenEnglish",
            dependencies: ["TelexCore"]
        ),
        .executableTarget(
            name: "GenGolden",
            dependencies: ["TelexCore"]
        ),
        .testTarget(
            name: "TelexCoreTests",
            dependencies: ["TelexCore"],
            resources: [.copy("Resources/telex_test_suite.csv"), .copy("Resources/spelling_error_cases.tsv")]
        )
    ]
)
