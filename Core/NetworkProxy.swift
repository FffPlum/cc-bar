import Foundation
import os

// MARK: - 网络代理
//
// cc-bar 的出网请求一律走 `NetworkProxy.data(for:)`，不要直接用 `URLSession.shared`
// （见 docs/技术实现.md「网络代理」）。两种模式，对 cc-bar 的全部请求生效：
// - 跟随系统：直接用 `URLSession.shared`，读 macOS 系统代理，与加入代理设置前完全一致。
// - 手动：用户填写的 HTTP / SOCKS5 代理。
// 手动模式下代理不可用时直接报错，不回退直连或系统代理：带着账号凭据的请求
// 换一个出口发出，服务端看到的就是同一账号在两个 IP 上同时使用。

nonisolated enum ProxyMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case manual

    var id: String { rawValue }
}

nonisolated enum ProxyType: String, CaseIterable, Identifiable, Sendable {
    case http
    case socks5

    var id: String { rawValue }
}

nonisolated struct ProxyEndpoint: Sendable, Equatable {
    var type: ProxyType
    var host: String
    var port: Int

    /// 界面与日志里显示的地址，如 `127.0.0.1:7890`。
    var address: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

nonisolated enum ProxyUnavailableReason: Sendable, Equatable {
    /// 手动模式下地址或端口没填好。
    case manualIncomplete
}

nonisolated enum ProxyResolution: Sendable, Equatable {
    case system
    case proxy(ProxyEndpoint)
    case unavailable(ProxyUnavailableReason)
}

/// 代理已开启但用不了时抛出；`QuotaError.from(transport:)` 把它归为 `.network(.proxyUnavailable)`。
nonisolated struct ProxyUnavailableError: Error, Sendable {
    let reason: ProxyUnavailableReason
}

nonisolated enum NetworkProxy {
    /// 与 `SettingsStore` 共用的 key：取数在后台线程直接读 UserDefaults，不经过主线程的 SettingsStore。
    enum Keys {
        static let mode = "ccbar.settings.proxyMode"
        static let type = "ccbar.settings.proxyType"
        static let host = "ccbar.settings.proxyHost"
        static let port = "ccbar.settings.proxyPort"
    }

    private struct State: Sendable {
        var endpoint: ProxyEndpoint?
        var session: URLSession?
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    // MARK: 请求

    /// 替代 `URLSession.shared.data(for:)`。`session` 只给需要注入会话的调用方用。
    static func data(for request: URLRequest, session: URLSession? = nil) async throws -> (Data, URLResponse) {
        let session = try session ?? currentSession()
        return try await session.data(for: request)
    }

    static func currentSession() throws -> URLSession {
        switch resolve() {
        case .system:
            return .shared
        case .proxy(let endpoint):
            return session(for: endpoint)
        case .unavailable(let reason):
            throw ProxyUnavailableError(reason: reason)
        }
    }

    /// 设置页「测试」按钮：用当前配置请求 Claude 状态页，收到任何 HTTP 响应就算连通。
    static func testConnection() async -> Result<Void, QuotaError> {
        var request = URLRequest(url: URL(string: "https://status.claude.com/api/v2/status.json")!)
        request.timeoutInterval = 10
        do {
            _ = try await data(for: request)
            return .success(())
        } catch {
            return .failure(.from(transport: error))
        }
    }

    // MARK: 解析配置

    static func resolve() -> ProxyResolution {
        let defaults = UserDefaults.standard
        let mode = defaults.string(forKey: Keys.mode).flatMap(ProxyMode.init(rawValue:)) ?? .system
        switch mode {
        case .system:
            return .system
        case .manual:
            return manualResolution(defaults: defaults)
        }
    }

    /// 当前生效的代理地址；跟随系统或代理不可用时为 nil。
    static var activeEndpoint: ProxyEndpoint? {
        if case .proxy(let endpoint) = resolve() { return endpoint }
        return nil
    }

    private static func manualResolution(defaults: UserDefaults) -> ProxyResolution {
        let type = defaults.string(forKey: Keys.type).flatMap(ProxyType.init(rawValue:)) ?? .http
        let host = (defaults.string(forKey: Keys.host) ?? "").trimmingCharacters(in: .whitespaces)
        let port = defaults.integer(forKey: Keys.port)
        guard !host.isEmpty,
              !host.contains("/"),
              !host.contains(where: \.isWhitespace),
              (1...65535).contains(port)
        else { return .unavailable(.manualIncomplete) }
        return .proxy(ProxyEndpoint(type: type, host: host, port: port))
    }

    // MARK: 会话

    /// 同一地址复用一个会话；地址变了就换新会话，旧会话等进行中的请求跑完再释放。
    private static func session(for endpoint: ProxyEndpoint) -> URLSession {
        state.withLock { current in
            if let session = current.session, current.endpoint == endpoint { return session }
            current.session?.finishTasksAndInvalidate()
            let session = makeSession(endpoint)
            current.endpoint = endpoint
            current.session = session
            return session
        }
    }

    private static func makeSession(_ endpoint: ProxyEndpoint) -> URLSession {
        var proxy: [String: Any] = [:]
        switch endpoint.type {
        case .http:
            proxy[kCFNetworkProxiesHTTPEnable as String] = 1
            proxy[kCFNetworkProxiesHTTPProxy as String] = endpoint.host
            proxy[kCFNetworkProxiesHTTPPort as String] = endpoint.port
            proxy[kCFNetworkProxiesHTTPSEnable as String] = 1
            proxy[kCFNetworkProxiesHTTPSProxy as String] = endpoint.host
            proxy[kCFNetworkProxiesHTTPSPort as String] = endpoint.port
        case .socks5:
            proxy[kCFNetworkProxiesSOCKSEnable as String] = 1
            proxy[kCFNetworkProxiesSOCKSProxy as String] = endpoint.host
            proxy[kCFNetworkProxiesSOCKSPort as String] = endpoint.port
        }
        let configuration = URLSessionConfiguration.default
        configuration.connectionProxyDictionary = proxy
        return URLSession(configuration: configuration)
    }

    // MARK: 子进程

    /// `claude`、`agy` 子进程的环境变量。它们是独立程序，只认代理环境变量，不读 cc-bar 的会话配置。
    /// 返回 nil 表示当前代理没法交给子进程，调用方应放弃启动，不要让它直连：
    /// 代理不可用，或代理是 SOCKS5（Claude Code 官方文档写明不支持 SOCKS 代理，agy 未确认支持）。
    static func subprocessEnvironment(base: [String: String]) -> [String: String]? {
        switch resolve() {
        case .system:
            return base
        case .unavailable:
            return nil
        case .proxy(let endpoint):
            guard endpoint.type == .http else { return nil }
            var environment = base
            let url = "http://\(endpoint.address)"
            for key in ["HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy"] {
                environment[key] = url
            }
            for key in ["ALL_PROXY", "all_proxy"] {
                environment.removeValue(forKey: key)
            }
            return environment
        }
    }
}
