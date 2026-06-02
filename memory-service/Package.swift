// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MemoryService",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "memory-service", targets: ["MemoryService"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.4.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.23.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "MemoryService",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Logging", package: "swift-log"),
            ]),
        .testTarget(
            name: "MemoryServiceTests",
            dependencies: [
                "MemoryService",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]),
    ]
)
