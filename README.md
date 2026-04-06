# PostProxyCore

## 系统要求

- iOS 13.0+ / macOS 10.15+ / watchOS 6.0+ / tvOS 13.0+
- Swift 5.9+
- Xcode 15.0+

## 安装

### Swift Package Manager

在 `Package.swift` 中添加依赖：

```swift
dependencies: [
	.package(url: "https://github.com/RayanceKing/PostProxyCore.git", from: "0.1.0")
]
```

或在 Xcode 中：

1. File → Add Package Dependencies
2. 输入仓库 URL: https://github.com/RayanceKing/PostProxyCore.git
3. 选择版本并添加到项目


PostProxyCore 是一个基于 Swift 的高性能 HTTP/HTTPS 代理核心库，支持 MITM（中间人）模式、请求转发、证书管理、历史记录存储等功能。适用于桌面端、移动端、AI 自动化和 UI 软件集成。

## 主要模块与功能

- **ProxyCore**：代理服务器核心，支持 MITM、会话管理、过滤等。
- **HTTPClient**：异步 HTTP 请求发送与响应处理。
- **CoreSecurity**：证书生成、管理与根证书信任。
- **Protocol**：统一的 HTTP 请求/响应/模板/历史等数据结构。
- **Storage**：历史记录存储接口与内存实现。

## 关键公开接口（Swift）

### 1. 代理服务器

- `ProxyServer`：主代理服务类
	- `init(configuration: ProxyServerConfiguration, ...)`
	- `func start() async throws` 启动代理服务
	- `func stop() async throws` 停止代理服务
- `ProxyServerConfiguration`：代理配置（host, port, mode, TLS 验证）
- `ProxyMode`：.passthrough / .mitm

### 2. MITM 中间人
- `MITMOrchestrating` 协议：自定义 MITM 行为
- `DefaultMITMOrchestrator`：默认实现，自动生成证书

### 3. HTTP 客户端
- `RequestSending` 协议：
	- `func send(_ request: HTTPRequest) async throws -> HTTPResponse`
- `NIORequestSender`：基于 SwiftNIO 的实现

### 4. 证书与信任管理
- `CertificateManaging` 协议、`MITMCertificateProviding` 协议
- `InMemoryCertificateManager`：内存证书管理
- `RootTrustManaging` 协议、`MacOSRootTrustManager`：根证书信任

### 5. 历史记录存储
- `HistoryStore` 协议：
	- `func save(_ record: HistoryRecord) async`
	- `func list(limit: Int) async -> [HistoryRecord]`
	- `func clear() async`
- `InMemoryHistoryStore`：内存实现

### 6. 数据结构（Protocol 模块）
- `HTTPRequest`、`HTTPResponse`、`RequestTemplate`、`HistoryRecord`、`ProxySession` 等

## 接入与调用建议

### Swift 代码集成
1. 通过 SwiftPM 引入本库
2. 创建 `ProxyServerConfiguration`，初始化 `ProxyServer`
3. 调用 `start()`/`stop()` 控制代理
4. 通过 `RequestSending` 发送 HTTP 请求
5. 通过 `HistoryStore` 获取历史记录


## 示例代码

```swift
import PostProxyCore

// 1. 启动代理服务器
let config = ProxyServerConfiguration(host: "127.0.0.1", port: 9090, mode: .mitm)
let proxy = ProxyServer(configuration: config)
try await proxy.start()

// 2. 发送 HTTP 请求
let sender = NIORequestSender()
let request = HTTPRequest(name: "Test", url: URL(string: "https://example.com")!, method: .get, headers: [:], body: .none)
let response = try await sender.send(request)

// 3. 查询历史记录
let store = InMemoryHistoryStore()
let records = await store.list(limit: 10)

// 4. 停止代理
try await proxy.stop()
```

## 依赖
- Swift 5.7+
- SwiftNIO, AsyncHTTPClient, NIOSSL, X509

## 许可证
AGNU