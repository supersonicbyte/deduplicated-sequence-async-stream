// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DeduplicatedSequenceAsyncStream",
    platforms: [
      .macOS(.v15),
      .iOS("13.0"),
      .tvOS("13.0"),
      .watchOS("6.0")
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "DeduplicatedSequenceAsyncStream",
            targets: ["DeduplicatedSequenceAsyncStream"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),
        .package(url: "https://github.com/ordo-one/package-benchmark", .upToNextMajor(from: "1.4.0")),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "DeduplicatedSequenceAsyncStream"),
        .testTarget(
            name: "DeduplicatedSequenceAsyncStreamTests",
            dependencies: ["DeduplicatedSequenceAsyncStream"]
        ),
    ]
)

// Benchmark of DeduplicatedSequenceAsyncStreamBenchmark
package.targets += [
    .executableTarget(
        name: "DeduplicatedSequenceAsyncStreamBenchmark",
        dependencies: [
            .product(name: "Benchmark", package: "package-benchmark"),
            .target(name: "DeduplicatedSequenceAsyncStream")
        ],
        path: "Benchmarks/DeduplicatedSequenceAsyncStreamBenchmark",
        plugins: [
            .plugin(name: "BenchmarkPlugin", package: "package-benchmark")
        ]
    ),
]
