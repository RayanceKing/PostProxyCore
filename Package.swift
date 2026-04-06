// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PostProxyCore",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .tvOS(.v15),
        .watchOS(.v8)
    ],
    products: [
        .library(name: "PostProxyCore", targets: ["PostProxyCore"]),
        .library(name: "Protocol", targets: ["Protocol"]),
        .library(name: "HTTPClient", targets: ["HTTPClient"]),
        .library(name: "Storage", targets: ["Storage"]),
        .library(name: "CoreSecurity", targets: ["CoreSecurity"]),
        .library(name: "ProxyCore", targets: ["ProxyCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.24.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.72.0"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.42.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.28.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.8.0")
    ],
    targets: [
        .target(name: "Protocol"),
        .target(
            name: "Storage",
            dependencies: ["Protocol"],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "CoreSecurity",
            dependencies: [
                "Protocol",
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOSSL", package: "swift-nio-ssl")
            ]
        ),
        .target(
            name: "HTTPClient",
            dependencies: [
                "Protocol",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOCore", package: "swift-nio")
            ]
        ),
        .target(
            name: "ProxyCore",
            dependencies: [
                "Protocol",
                "CoreSecurity",
                "Storage",
                "HTTPClient",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "NIOSSL", package: "swift-nio-ssl")
            ]
        ),
        .target(
            name: "PostProxyCore",
            dependencies: ["Protocol", "HTTPClient", "Storage", "CoreSecurity", "ProxyCore"]
        ),
        .testTarget(name: "ProtocolTests", dependencies: ["Protocol"]),
        .testTarget(name: "HTTPClientTests", dependencies: ["HTTPClient", "Protocol"]),
        .testTarget(name: "CoreSecurityTests", dependencies: ["CoreSecurity"]),
        .testTarget(name: "StorageTests", dependencies: ["Storage", "Protocol"]),
        .testTarget(
            name: "ProxyCoreTests",
            dependencies: ["ProxyCore", "Protocol", "Storage", "HTTPClient"]
        )
    ],
    swiftLanguageModes: [.v6]
)
