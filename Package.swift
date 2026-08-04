// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "OpenWhisper",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.12.4"),
    ],
    targets: [
        .systemLibrary(
            name: "CDeepFilter",
            path: "Vendor/DeepFilter"
        ),
        .executableTarget(
            name: "OpenWhisper",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                "CDeepFilter",
            ],
            path: "OpenWhisper",
            exclude: ["Info.plist", "OpenWhisper.entitlements"],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                // libDF (DeepFilterNet 3's Rust core, `capi` feature) is vendored as a prebuilt
                // dylib — see Vendor/DeepFilter/README.md for how it was built. It carries
                // install name @rpath/libdf.dylib; build.sh copies it next to the executable,
                // which is already on the linker-provided @loader_path rpath.
                .unsafeFlags(["-L", "Vendor/DeepFilter/lib", "-ldf"])
            ]
        ),
        .testTarget(
            name: "OpenWhisperTests",
            dependencies: ["OpenWhisper"]
        ),
    ]
)
