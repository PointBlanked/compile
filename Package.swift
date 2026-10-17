// swift-tools-version: 5.10
// Owner: Maxwell (infrastructure). One target per co-founder so nobody edits
// another person's target, plus a small shared Contracts target that every
// engine depends on and nobody else imports across.
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
        // Shared types and protocols. Changes here need review from all four owners.
        .target(
            name: "EchoGuideContracts",
            path: "EchoGuide/Core/Contracts"
        ),
        // James: camera feed, frame delta, local vision, digital fence.
        .target(
            name: "EchoGuideVision",
            dependencies: ["EchoGuideContracts"],
            path: "EchoGuide/Core",
            exclude: ["Contracts", "Haptics", "Depth", "Audio", "Automation", "Cognitive", "Plugins", "Router"],
            sources: ["Camera", "Vision", "Fence"]
        ),
        // Lily: haptics, LiDAR depth, spatial audio.
        .target(
            name: "EchoGuideSpatial",
            dependencies: ["EchoGuideContracts"],
            path: "EchoGuide/Core",
            exclude: ["Contracts", "Camera", "Vision", "Fence", "Automation", "Cognitive", "Plugins", "Router"],
            sources: ["Haptics", "Depth", "Audio"]
        ),
        // Bryan: automation state machine, cognitive isolation, SwiftUI.
        .target(
            name: "EchoGuideAutomation",
            dependencies: ["EchoGuideContracts"],
            path: "EchoGuide",
            exclude: ["Core/Contracts", "Core/Camera", "Core/Vision", "Core/Fence", "Core/Haptics", "Core/Depth", "Core/Audio", "Core/Plugins", "Core/Router"],
            sources: ["Core/Automation", "Core/Cognitive", "UI"]
        ),
        // Maxwell: plugin registry (MCP), cloud reasoning router.
        .target(
            name: "EchoGuideInfra",
            dependencies: ["EchoGuideContracts"],
            path: "EchoGuide/Core",
            exclude: ["Contracts", "Camera", "Vision", "Fence", "Haptics", "Depth", "Audio", "Automation", "Cognitive"],
            sources: ["Plugins", "Router"]
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
