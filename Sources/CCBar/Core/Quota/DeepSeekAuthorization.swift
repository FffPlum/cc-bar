import AppKit
import CryptoKit
import Network
import Security

/// One short-lived loopback listener per sign-in. No browser cookies or passwords are read.
@MainActor
final class DeepSeekAuthorization {
    struct Grant {
        var token: String
        var completionURL: URL
    }
    private let metadata = DeepSeekClient.ClientMetadata.current
    private var listener: NWListener?
    private var ready: CheckedContinuation<UInt16, Error>?
    private var callback: CheckedContinuation<String, Error>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var browserConnection: NWConnection?
    private var timeout: Task<Void, Never>?
    /// State-only notifications; browser URLs, codes and credentials stay in this owner.
    var onStateChange: (() -> Void)?
    var isWaitingForBrowser: Bool { waitingForBrowser && !ended }
    private var ended = false {
        didSet { if ended != oldValue { onStateChange?() } }
    }
    private var waitingForBrowser = false {
        didSet { if waitingForBrowser != oldValue { onStateChange?() } }
    }
    private var verifier = ""
    private var state = ""
    private var authorizeID: String?
    private var expiresAt = Date.distantPast

    func authorize() async throws -> Grant {
        try await withTaskCancellationHandler {
            do { return try await run() }
            catch { cancel(); throw error }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    private func run() async throws -> Grant {
        try Task.checkCancellation()
        guard !ended else { throw CancellationError() }
        verifier = try Self.randomToken()
        state = try Self.randomToken()
        expiresAt = Date().addingTimeInterval(600)
        armTimeout(seconds: 600)
        let port = try await startListener()
        try checkActive()
        let redirectURI = "http://127.0.0.1:\(port)/oauth/callback"
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        struct Initialization: Decodable {
            var authorize_url, authorize_id: String
            var expires_in: Double
        }
        let data = try await DeepSeekClient.request(path: "/auth-api/v0/dsh/auth_init", body: [
            "code_challenge": challenge, "code_challenge_method": "S256", "state": state,
            "redirect_uri": redirectURI, "locale": metadata.locale, "login_source": "desktop"
        ], metadata: metadata)
        let initialization = try JSONDecoder().decode(Initialization.self, from: data)
        authorizeID = initialization.authorize_id
        try checkActive()
        guard !initialization.authorize_id.isEmpty, initialization.expires_in.isFinite,
              initialization.expires_in > 0 else { throw QuotaError.decode("invalid DeepSeek authorization lifetime") }
        let url = try DeepSeekClient.browserURL(initialization.authorize_url, path: "/dsh/authorize")
        expiresAt = min(expiresAt, Date().addingTimeInterval(initialization.expires_in))
        armTimeout(seconds: max(0, expiresAt.timeIntervalSinceNow))
        let code: String = try await withCheckedThrowingContinuation { continuation in
            callback = continuation
            waitingForBrowser = true
            if !NSWorkspace.shared.open(url) {
                fail(QuotaError.transport("Could not open browser"))
            }
        }
        try checkActive()
        let defaults = UserDefaults.standard
        let deviceKey = "ccbar.deepseek.deviceID"
        let deviceID = defaults.string(forKey: deviceKey).flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(deviceID.uuidString, forKey: deviceKey)
        #if arch(arm64)
        let model = "darwin-arm64"
        #else
        let model = "darwin-x64"
        #endif
        struct Exchange: Decodable {
            var token, authorized_url: String
        }
        let exchanged = try await DeepSeekClient.request(path: "/auth-api/v0/dsh/auth_exchange", body: [
            "code": code, "code_verifier": verifier, "redirect_uri": redirectURI,
            "device_id": deviceID.uuidString, "device_model": model,
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString
        ], metadata: metadata)
        try checkActive()
        let result = try JSONDecoder().decode(Exchange.self, from: exchanged)
        guard DeepSeekAccount.validSecret(result.token) else { throw QuotaError.decode("invalid DeepSeek token") }
        let completion = try DeepSeekClient.browserURL(result.authorized_url, path: "/dsh/authorized")
        return Grant(token: result.token, completionURL: completion)
    }

    /// Recheck on the UI actor immediately before the synchronous credential commit.
    func validateForCommit() throws { try checkActive() }

    /// Called only after the credential and metadata have both been saved.
    func finish(completionURL: URL) {
        ended = true
        timeout?.cancel()
        var components = URLComponents(url: completionURL, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []).filter { $0.name != "login_source" }
            + [URLQueryItem(name: "login_source", value: "desktop")]
        if let connection = browserConnection {
            respond(connection, status: "302 Found", location: components.url!.absoluteString)
            browserConnection = nil
        }
        closeListener()
        authorizeID = nil
    }

    func cancel() {
        let id = authorizeID
        authorizeID = nil
        fail(CancellationError())
        if let id {
            let body = ["authorize_id": id, "code_verifier": verifier]
            let metadata = metadata
            Task { _ = try? await DeepSeekClient.request(path: "/auth-api/v0/dsh/auth_cancel", body: body, metadata: metadata) }
        }
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        guard !ended, Date() < expiresAt else { throw QuotaError.transport("DeepSeek sign-in expired") }
    }
    private func armTimeout(seconds: TimeInterval) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.fail(QuotaError.transport("DeepSeek sign-in expired"))
        }
    }
    private func fail(_ error: Error) {
        ended = true
        timeout?.cancel()
        ready?.resume(throwing: error); ready = nil
        callback?.resume(throwing: error); callback = nil
        if let connection = browserConnection { respond(connection, status: "204 No Content") }
        browserConnection = nil
        closeListener()
    }
    private func closeListener() {
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    private func startListener() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        server.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { @MainActor in self.accept(connection) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            server.stateUpdateHandler = { [weak self, weak server] status in
                guard let self else { return }
                let port = server?.port?.rawValue
                Task { @MainActor in
                    guard !self.ended else { return }
                    switch status {
                    case .ready:
                        if let port {
                            self.ready?.resume(returning: port); self.ready = nil
                        }
                    case .failed: self.fail(QuotaError.transport("DeepSeek callback unavailable"))
                    default: break
                    }
                }
            }
            server.start(queue: .main)
        }
    }
    private func accept(_ connection: NWConnection) {
        guard !ended, connections.count < 8 else { connection.cancel(); return }
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            Task { @MainActor in
                guard !self.ended else { connection.cancel(); return }
                let combined = buffer + (data ?? Data())
                guard combined.count <= 8192, error == nil else {
                    self.respond(connection, status: "400 Bad Request"); return
                }
                if let request = String(data: combined, encoding: .utf8), request.contains("\r\n\r\n") {
                    self.handle(request, connection: connection)
                } else if complete {
                    self.respond(connection, status: "400 Bad Request")
                } else { self.receive(connection, buffer: combined) }
            }
        }
    }
    static func callbackCode(request: String, expectedState: String) -> String? {
        let line = request.components(separatedBy: "\r\n").first ?? ""
        let pieces = line.split(separator: " ")
        guard pieces.count == 3, pieces[0] == "GET", pieces[2] == "HTTP/1.1",
              pieces[1].hasPrefix("/oauth/callback?"),
              let components = URLComponents(string: "http://127.0.0.1" + pieces[1]),
              components.path == "/oauth/callback", components.fragment == nil else { return nil }
        let states = (components.queryItems ?? []).filter { $0.name == "state" }
        let codes = (components.queryItems ?? []).filter { $0.name == "code" }
        guard states.count == 1, codes.count == 1, let state = states[0].value,
              constantTimeEqual(state, expectedState), let code = codes[0].value,
              DeepSeekAccount.validSecret(code) else { return nil }
        return code
    }
    private func handle(_ request: String, connection: NWConnection) {
        guard let code = Self.callbackCode(request: request, expectedState: state) else {
            respond(connection, status: "400 Bad Request"); return
        }
        guard waitingForBrowser, callback != nil, Date() < expiresAt else {
            respond(connection, status: "410 Gone"); return
        }
        waitingForBrowser = false
        connections[ObjectIdentifier(connection)] = nil
        browserConnection = connection
        callback?.resume(returning: code); callback = nil
    }
    private func respond(_ connection: NWConnection, status: String, location: String? = nil) {
        connections[ObjectIdentifier(connection)] = nil
        let redirect = location.map { "Location: \($0)\r\n" } ?? ""
        let reply = "HTTP/1.1 \(status)\r\n\(redirect)Cache-Control: no-store\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw QuotaError.transport("Could not initialize secure sign-in")
        }
        return Data(bytes).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
