// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceInput",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpeechFoundation", targets: ["SpeechFoundation"]),
        .library(name: "SpeechInput", targets: ["SpeechInput"]),
        .executable(name: "voice-input", targets: ["VoiceInputCLI"]),
        .executable(name: "voice-demo", targets: ["VoiceDemo"]),
    ],
    dependencies: [.package(path: ".runtime/RxSwift-6.10.2")],
    targets: [
        .target(name: "SpeechFoundation", path: "src/foundation", exclude: ["Audio/Tests", "Recognition/Tests", "CLI/Tests", "Live/Tests", "Correction/Tests"]),
        .testTarget(name: "CorrectionValueTests", dependencies: ["SpeechFoundation"], path: "src/foundation/Correction/Tests"),
        .testTarget(name: "LiveStateTests", dependencies: ["SpeechFoundation"], path: "src/foundation/Live/Tests"),
        .testTarget(name: "AudioTests", dependencies: ["SpeechFoundation"], path: "src/foundation/Audio/Tests"),
        .testTarget(name: "RecognitionTests", dependencies: ["SpeechFoundation"], path: "src/foundation/Recognition/Tests"),
        .testTarget(name: "CLIArgumentTests", dependencies: ["SpeechFoundation"], path: "src/foundation/CLI/Tests"),
        .target(name: "SpeechInput", dependencies: ["SpeechFoundation", .product(name: "RxSwift", package: "RxSwift-6.10.2")], path: "src/business", exclude: ["Whisper/Tests", "Process/Tests", "CommandLine", "Live/Tests", "Capture/Tests", "Desktop", "Qwen/Tests", "Correction/Tests", "QwenASR/Runtime", "QwenASR/Tests"]),
        .testTarget(name: "QwenASRTests", dependencies: ["SpeechInput", "SpeechFoundation"], path: "src/business/QwenASR/Tests"),
        .testTarget(name: "QwenTests", dependencies: ["SpeechInput", "SpeechFoundation"], path: "src/business/Qwen/Tests"),
        .testTarget(name: "CorrectionSessionTests", dependencies: ["SpeechInput", "SpeechFoundation"], path: "src/business/Correction/Tests"),
        .testTarget(name: "LiveSessionTests", dependencies: ["SpeechInput", "SpeechFoundation"], path: "src/business/Live/Tests"),
        .testTarget(name: "CaptureTests", dependencies: ["SpeechInput", "SpeechFoundation"], path: "src/business/Capture/Tests"),
        .target(name: "VoiceDemoUI", dependencies: ["SpeechInput", "SpeechFoundation"], path: "src/business/Desktop", exclude: ["Tests", "App"]),
        .executableTarget(name: "VoiceDemo", dependencies: ["VoiceDemoUI"], path: "src/business/Desktop/App"),
        .testTarget(name: "DesktopTests", dependencies: ["VoiceDemoUI", "SpeechInput", "SpeechFoundation"], path: "src/business/Desktop/Tests"),
        .testTarget(name: "WhisperTests", dependencies: ["SpeechInput", "SpeechFoundation"], path: "src/business/Whisper/Tests"),
        .testTarget(name: "ProcessTests", dependencies: ["SpeechInput", "SpeechFoundation"], path: "src/business/Process/Tests", resources: [.copy("Fixtures")]),
        .executableTarget(name: "VoiceInputCLI", dependencies: ["SpeechInput", "SpeechFoundation"], path: "src/business/CommandLine", exclude: ["Tests"]),
        .testTarget(name: "CommandLineTests", dependencies: ["SpeechFoundation"], path: "src/business/CommandLine/Tests", resources: [.copy("Fixtures")]),
    ]
)
