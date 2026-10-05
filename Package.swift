// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Loopl",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        // The SDK core — pure Swift (Foundation only). Agent loop, Model/Tool protocols,
        // tool-call parsers, prompt rendering, catalog, Hugging Face downloader.
        .library(name: "Loopl", targets: ["Loopl"]),
        // Engines: MLXModel (mlx-swift-lm, Metal, real device), AppleFoundationModel (iOS 26), GGUFModel (v2 stub).
        .library(name: "LooplRuntimes", targets: ["LooplRuntimes"]),
        // SwiftUI showcase components: ToolCallCard, TokenMeter, AgentTranscriptView, …
        .library(name: "LooplUI", targets: ["LooplUI"]),
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
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Hub", package: "swift-transformers"),
            ],
            path: "Sources/LooplRuntimes",
            swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "LooplUI", dependencies: ["Loopl"], path: "Sources/LooplUI", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "LooplTests", dependencies: ["Loopl"], path: "Tests/LooplTests",
                    resources: [.copy("Fixtures")], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
