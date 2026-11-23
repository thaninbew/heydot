// swift-tools-version: 6.0
import PackageDescription

// HeyDot: a menu bar app that hears "Hey <your dot>" on device and starts the dot's
// call in HeyDot's signed-in hidden browser.
let package = Package(
    name: "HeyDot",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Self-updates. Exact official release; build-app.sh embeds and re-signs the framework.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // On-device keyword spotting (sherpa-onnx C API), microphone capture, enrollment calibration.
        // Owned by the engine workstream. Exposes only the contract in WakeEngineAPI.swift.
        .systemLibrary(name: "CSherpa", path: "Sources/WakeEngine/CSherpa"),
        .target(name: "WakeEngine", dependencies: ["CSherpa"], path: "Sources/WakeEngine",
                exclude: ["CSherpa", "EngineCheck"], linkerSettings: [
                    .unsafeFlags(["-L" + String(#filePath.dropLast("Package.swift".count)) + "Vendor/sherpa-onnx-v1.13.8-osx-arm64-static-no-tts-lib/lib"]),
                    .linkedLibrary("sherpa-onnx-c-api"), .linkedLibrary("sherpa-onnx-core"),
                    .linkedLibrary("onnxruntime"), .linkedLibrary("kaldi-native-fbank-core"),
                    .linkedLibrary("kissfft-float"), .linkedLibrary("ssentencepiece_core"),
                    .linkedLibrary("sherpa-onnx-fst"), .linkedLibrary("sherpa-onnx-fstfar"),
                    .linkedLibrary("sherpa-onnx-kaldifst-core"), .linkedLibrary("kaldi-decoder-core"),
                    .linkedLibrary("c++"), .linkedFramework("Accelerate")
                ]),
        .executableTarget(name: "heydot-engine-check", dependencies: ["WakeEngine"], path: "Sources/WakeEngine/EngineCheck"),
        // The menu bar app: onboarding, dot maker and hidden browser.
        // Owned by the app workstream.
        .target(name: "HeyDotKit", dependencies: ["WakeEngine", .product(name: "Sparkle", package: "Sparkle")], path: "Sources/HeyDot/Kit",
                // The avatar prompt, compiled into the binary (no resource bundle to ship).
                resources: [.embedInCode("Resources/AvatarAgentPrompt.md"),
                            .embedInCode("Resources/Logo8_1024.png"), .embedInCode("Resources/Logo8_32.png"),
                            .embedInCode("Resources/Logo8_16.png")]),
        .executableTarget(name: "HeyDot", dependencies: ["HeyDotKit"], path: "Sources/HeyDot/Main",
                          // Finds the bundled Sparkle.framework in HeyDot.app/Contents/Frameworks.
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "HeyDotTests", dependencies: ["HeyDotKit", "WakeEngine"], path: "Tests/HeyDotTests"),
        .testTarget(name: "WakeEngineTests", dependencies: ["WakeEngine"], path: "Tests/WakeEngineTests", resources: [.copy("Fixtures")]),
    ]
)
