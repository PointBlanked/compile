// swift-tools-version: 5.10
// Owner: Maxwell (infrastructure). Targets split by engine; ownership between the two
// co-founders is in .github/CODEOWNERS. Engines only meet through the shared
// Contracts target, so two people never edit the same file.
import PackageDescription

let package = Package(
    name: "AutoVisionAudioEngine",
    platforms: [
        .iOS(.v17),
        // macOS is a build-and-test host only: ARKit, the camera and haptics are
        // compiled out there, the pure logic underneath them still runs in CI.
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "EchoGuide",
            targets: [
                "EchoGuideContracts",
                "EchoGuideVision",
                "EchoGuideSpatial",
                "EchoGuideAutomation",
                "EchoGuideInfra",
            ]
        ),
    ],
    targets: [
        // Shared types and protocols. Changes here need review from both owners.
        .target(
            name: "EchoGuideContracts",
            path: "EchoGuide/Core/Contracts"
        ),
        // Camera, frame delta, local vision (Maxwell); digital fence (Bryan).
        .target(
            name: "EchoGuideVision",
            dependencies: ["EchoGuideContracts"],
            path: "EchoGuide/Core",
            exclude: ["Contracts", "Haptics", "Depth", "Audio", "Automation", "Cognitive", "Plugins", "Router", "Agent"],
            sources: ["Camera", "Vision", "Fence"]
        ),
        // Haptics, spatial audio (Bryan); LiDAR depth (Maxwell).
        .target(
            name: "EchoGuideSpatial",
            dependencies: ["EchoGuideContracts"],
            path: "EchoGuide/Core",
            exclude: ["Contracts", "Camera", "Vision", "Fence", "Automation", "Cognitive", "Plugins", "Router", "Agent"],
            sources: ["Haptics", "Depth", "Audio"]
        ),
        // Bryan: automation state machine, cognitive isolation, SwiftUI.
        .target(
            name: "EchoGuideAutomation",
            dependencies: ["EchoGuideContracts"],
            path: "EchoGuide",
            exclude: ["Core/Contracts", "Core/Camera", "Core/Vision", "Core/Fence", "Core/Haptics", "Core/Depth", "Core/Audio", "Core/Plugins", "Core/Router", "Core/Agent"],
            sources: ["Core/Automation", "Core/Cognitive", "UI"]
        ),
        // Maxwell: plugin registry (MCP), cloud reasoning router, the visual agent.
        .target(
            name: "EchoGuideInfra",
            dependencies: ["EchoGuideContracts"],
            path: "EchoGuide/Core",
            exclude: ["Contracts", "Camera", "Vision", "Fence", "Haptics", "Depth", "Audio", "Automation", "Cognitive"],
            sources: ["Plugins", "Router", "Agent"]
        ),
        // Maxwell: reproducible benchmarks of the real engine code. `swift run -c release EchoGuideBench`
        .executableTarget(
            name: "EchoGuideBench",
            dependencies: ["EchoGuideContracts", "EchoGuideVision", "EchoGuideInfra"],
            path: "EchoGuideBench"
        ),
        .testTarget(
            name: "EchoGuideTests",
            dependencies: [
                "EchoGuideContracts",
                "EchoGuideVision",
                "EchoGuideSpatial",
                "EchoGuideAutomation",
                "EchoGuideInfra",
            ],
            path: "EchoGuideTests"
        ),
    ]
)
