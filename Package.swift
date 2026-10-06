// swift-tools-version: 6.0
import PackageDescription
import Foundation

// llama.cpp (GGUF runtime) is an optional vendored xcframework: run
// `scripts/fetch-llama-xcframework.sh [--with-sim]` to put the official
// ggml-org release at Vendor/llama.xcframework (gitignored). When it is
// there, LooplRuntimes links it and GGUFModel is real; when it is not,
// `canImport(llama)` is false and GGUFModel reports itself unavailable.
// (A URL binaryTarget is not used because the official zip has no iOS
// Simulator slice — it would fail every simulator build at link time.)
let llamaXCFramework = "Vendor/llama.xcframework"
let hasLlama = FileManager.default.fileExists(atPath: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(llamaXCFramework).path)

let package = Package(
    name: "Loopl",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        // The SDK core — pure Swift (Foundation only). Agent loop, Model/Tool protocols,
        // tool-call parsers, prompt rendering, catalog, Hugging Face downloader.
        .library(name: "Loopl", targets: ["Loopl"]),
        // Engines: MLXModel (mlx-swift-lm, Metal, real device; MLXVLM for vision checkpoints), AppleFoundationModel (iOS 26), GGUFModel.
        .library(name: "LooplRuntimes", targets: ["LooplRuntimes"]),
        // SwiftUI showcase components: ToolCallCard, TokenMeter, AgentTranscriptView, …
        .library(name: "LooplUI", targets: ["LooplUI"]),
        // The iPhone's own intelligence as tools: generate_image, generate_voice, read_text, describe_image, translate, transcribe, …
        .library(name: "LooplAppleTools", targets: ["LooplAppleTools"]),
    ],
    dependencies: [
        // MLXLLM/MLXLMCommon moved out of mlx-swift-examples into mlx-swift-lm (3.x).
        // We link only MLXLLM + MLXLMCommon — never MLXHuggingFace (its macros pull
        // MLXFoundationModels, which needs iOS 27 types under the default trait).
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.4"),
    ],
    targets: [
        .target(name: "Loopl", path: "Sources/Loopl", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(
            name: "LooplRuntimes",
            dependencies: [
                "Loopl",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),   // vision checkpoints (Qwen3-VL / Qwen3.5 / Gemma 3…)
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Hub", package: "swift-transformers"),
            ] + (hasLlama ? [.target(name: "llama")] : []),
            path: "Sources/LooplRuntimes",
            swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "LooplUI", dependencies: ["Loopl"], path: "Sources/LooplUI", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "LooplAppleTools", dependencies: ["Loopl"], path: "Sources/LooplAppleTools", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "LooplAppleToolsTests", dependencies: ["Loopl", "LooplAppleTools"], path: "Tests/LooplAppleToolsTests",
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "LooplTests", dependencies: ["Loopl"], path: "Tests/LooplTests",
                    resources: [.copy("Fixtures")], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "LooplRuntimesTests", dependencies: ["Loopl", "LooplRuntimes"], path: "Tests/LooplRuntimesTests",
                    resources: [.copy("Fixtures")], swiftSettings: [.swiftLanguageMode(.v6)]),
    ] + (hasLlama ? [.binaryTarget(name: "llama", path: llamaXCFramework)] : [])
)
