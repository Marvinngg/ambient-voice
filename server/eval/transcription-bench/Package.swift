// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TranscriptionBench",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "transcription-bench",
            path: "Sources"
        )
    ]
)
