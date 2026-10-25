import CommonCrypto
import Foundation
import os
import SQLite3

nonisolated struct CursorAuthSession: Sendable, Equatable {
    let accessToken: String
    let subject: String
    let userID: String
    let email: String?
    let expiresAt: Date

    var cookieHeader: String {
        "WorkosCursorSessionToken=\(userID)%3A%3A\(accessToken)"
    }

    func belongsToSameAccount(as other: CursorAuthSession) -> Bool {
        let lhsSubject = userID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rhsSubject = other.userID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !lhsSubject.isEmpty, !rhsSubject.isEmpty {
            return lhsSubject == rhsSubject
        }
        guard let lhsEmail = normalizedEmail(email),
              let rhsEmail = normalizedEmail(other.email)
        else { return false }
        return lhsEmail == rhsEmail
    }

    private func normalizedEmail(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }
}

/// 只读采用 Cursor.app 的当前登录态。
///
/// 只读取 `cursorAuth/accessToken`；不读取 refresh token，不调用 OAuth，
/// 不写 Cursor SQLite，也不把凭据保存到 cc-bar 的 Keychain、设置或缓存。
///
/// Cursor 服务端实验 `cursor_auth_token_encryption_at_rest` 打开后（3.27 起按账号灰度），
/// 这一项改存为 `cursor-safe-storage:v1:<base64>`，需要经钥匙串 `Cursor Safe Storage`
/// 解密，见下方「加密的登录态」。明文 JWT 照旧直接使用。
nonisolated enum CursorAuth {
    private static let accessTokenKey = "cursorAuth/accessToken"
    private static let expirationLeeway: TimeInterval = 60
    private static let sqliteBusyTimeoutMilliseconds: Int32 = 250

    // 加密登录态。格式与 Claude Desktop 相同（Electron safeStorage，见 `ClaudeDesktopAuth`）：
    // base64 解码后以 `v10` 开头，其后为 AES-128-CBC 密文，IV 为 16 个空格；
    // 密钥 = PBKDF2-SHA1(钥匙串 `Cursor Safe Storage` 的密码, salt `saltysalt`, 1003 轮, 16 字节)。
    private static let sealedPrefix = "cursor-safe-storage:"
    private static let sealedV1Prefix = "cursor-safe-storage:v1:"
    private static let safeStorageService = "Cursor Safe Storage"
    /// 远大于真实 token（约 600 字节），挡住异常大的值。
    private static let sealedValueLimit = 16 * 1024
    /// 用户拒绝过钥匙串授权后不再自动重试的标记。
    private static let denialDefaultsKey = "cursorSafeStorageAccessDeniedV1"
    /// 用户看过授权说明并选择继续的标记。没有它时不碰钥匙串，见 `deriveEncryptionKey()`。
    private static let explainedDefaultsKey = "cursorSafeStorageExplainedV1"
    /// `security` 的退出码取 OSStatus 低 8 位：51 = errSecAuthFailed（授权框点「拒绝」），
    /// 128 = errSecUserCanceled。
    private static let securityDeniedExitCodes: Set<Int32> = [51, 128]
    /// 派生出的 AES 密钥，进程内缓存，不落盘。用户只点「允许」（不是「始终允许」）时，
    /// 每次调用 `security` 都会再弹一次，缓存把它限制在每次启动最多一次。
    private static let cachedKey = OSAllocatedUnfairLock<Data?>(initialState: nil)
    /// 串行化钥匙串读取：授权框等用户响应时，并发的读取排队等结果，不叠出第二个框。
    private static let keychainReadLock = NSLock()
    /// 需要读钥匙串、但用户还没看过授权说明时登记，由 AppState 取走后弹说明框。
    private static let explanationRequest = OSAllocatedUnfairLock(initialState: false)

    static func defaultDatabaseURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Cursor", isDirectory: true)
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("globalStorage", isDirectory: true)
            .appendingPathComponent("state.vscdb", isDirectory: false)
    }

    /// `allowKeychainRead` 为 false 时，加密的登录态只用进程内已缓存的密钥解密，
    /// 不调用 `security`、不登记授权说明，用于 Cursor 未开启时的登录态检测。
    static func load(
        databaseURL: URL = defaultDatabaseURL(),
        now: Date = Date(),
        allowKeychainRead: Bool = true
    ) throws -> CursorAuthSession? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        guard let token = try CursorSQLiteReader(databaseURL: databaseURL).value(for: accessTokenKey) else {
            return nil
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let accessToken = trimmed.hasPrefix(sealedPrefix)
            ? try unsealAccessToken(trimmed, allowKeychainRead: allowKeychainRead)
            : trimmed
        return try session(accessToken: accessToken, now: now)
    }

    static func session(accessToken: String, now: Date = Date()) throws -> CursorAuthSession {
        guard let payload = JWT.decodePayload(accessToken) else {
            throw CursorAuthError.invalidToken("access token is not a valid JWT")
        }
        guard let subject = nonEmpty(payload["sub"] as? String),
              let userID = subject.split(separator: "|", omittingEmptySubsequences: true).last.map(String.init),
              !userID.isEmpty
        else {
            throw CursorAuthError.invalidToken("access token is missing a user ID")
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard userID.unicodeScalars.allSatisfy(allowed.contains) else {
            throw CursorAuthError.invalidToken("access token contains an unsafe user ID")
        }
        guard let expiration = number(payload["exp"]) else {
            throw CursorAuthError.invalidToken("access token is missing an expiration")
        }

        let expiresAt = Date(timeIntervalSince1970: expiration)
        guard expiresAt.timeIntervalSince(now) > expirationLeeway else {
            throw CursorAuthError.expired
        }

        return CursorAuthSession(
            accessToken: accessToken,
            subject: subject,
            userID: userID,
            email: nonEmpty(payload["email"] as? String),
            expiresAt: expiresAt
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func number(_ value: Any?) -> Double? {
        if value is Bool { return nil }
        let parsed: Double?
        switch value {
        case let value as NSNumber:
            parsed = value.doubleValue
        case let value as String:
            parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            parsed = nil
        }
        guard let parsed, parsed.isFinite else { return nil }
        return parsed
    }

    // MARK: - 加密的登录态

    static var hasUserDeniedAccess: Bool {
        UserDefaults.standard.bool(forKey: denialDefaultsKey)
    }

    /// 供设置页「授权…」用：清掉"用户拒绝过"的标记，下次需要时会重新尝试。
    static func clearDenial() {
        UserDefaults.standard.removeObject(forKey: denialDefaultsKey)
    }

    /// 用户在授权说明框里选了「暂不」，与在系统授权框里拒绝同样处理。
    static func recordDenial() {
        UserDefaults.standard.set(true, forKey: denialDefaultsKey)
    }

    static var hasExplainedAccess: Bool {
        UserDefaults.standard.bool(forKey: explainedDefaultsKey)
    }

    static func markAccessExplained() {
        UserDefaults.standard.set(true, forKey: explainedDefaultsKey)
    }

    /// 取走并清除待弹的授权说明请求。
    static func takeExplanationRequest() -> Bool {
        explanationRequest.withLock { requested in
            defer { requested = false }
            return requested
        }
    }

    private static func unsealAccessToken(_ value: String, allowKeychainRead: Bool) throws -> String {
        guard let ciphertext = sealedCiphertext(value) else {
            throw CursorAuthError.invalidToken("encrypted access token has an unsupported format")
        }
        if let key = cachedKey.withLock({ $0 }) {
            if let token = decryptAccessToken(ciphertext: ciphertext, key: key) { return token }
            // Cursor 重装后会换一把密钥，缓存的旧密钥解不开；丢掉它，下面重读一次。
            cachedKey.withLock { $0 = nil }
        }
        guard allowKeychainRead else {
            throw CursorAuthError.keychainAccessRequired(denied: hasUserDeniedAccess)
        }
        let key = try deriveEncryptionKey()
        // 刚读到的密钥也解不开时保留缓存：密钥是当前的，问题在数据，重读钥匙串只会多弹框。
        guard let token = decryptAccessToken(ciphertext: ciphertext, key: key) else {
            throw CursorAuthError.undecryptable
        }
        return token
    }

    /// 读 `Cursor Safe Storage` 的密码并派生 AES 密钥。
    ///
    /// 用户还没看过授权说明时不碰钥匙串，只登记一次说明请求，由 AppState 在主线程
    /// 先弹说明框——否则系统授权框会在后台刷新时毫无预告地出现，而且申请方显示为
    /// 「security」，用户看不懂。用户拒绝后记下标记，不再反复弹。
    private static func deriveEncryptionKey() throws -> Data {
        keychainReadLock.lock()
        defer { keychainReadLock.unlock() }
        // 排队期间可能已有别的调用读到。
        if let key = cachedKey.withLock({ $0 }) { return key }
        guard !hasUserDeniedAccess else {
            throw CursorAuthError.keychainAccessRequired(denied: true)
        }
        guard hasExplainedAccess else {
            explanationRequest.withLock { $0 = true }
            AppLog.info(.credentials, "Cursor keychain access not explained yet; waiting for the explanation dialog")
            throw CursorAuthError.keychainAccessRequired(denied: false)
        }
        let password: String
        switch readSafeStoragePassword() {
        case .success(let value):
            password = value
        case .denied:
            recordDenial()
            AppLog.info(.credentials, "user denied Cursor Safe Storage access; will not ask again automatically")
            throw CursorAuthError.keychainAccessRequired(denied: true)
        case .missing:
            throw CursorAuthError.keychainUnavailable
        }
        guard let key = encryptionKey(password: password) else {
            throw CursorAuthError.keychainUnavailable
        }
        cachedKey.withLock { $0 = key }
        return key
    }

    private enum PasswordReadResult {
        case success(String)
        case denied
        case missing
    }

    /// 通过系统自带的 `/usr/bin/security` 读密码，而不是在进程内调 Keychain Services。
    ///
    /// 与 `ClaudeDesktopAuth` 同样的取舍：cc-bar 是 ad-hoc 签名，进程内读取时用户点过的
    /// 「始终允许」在下次更新后就失效；授权记在苹果签名的 `security` 上则跨版本有效。
    /// 代价是授权后，本机同一用户的其他进程也能经 `security` 静默读到这条密码。
    /// 只按 service 查询：不同 Cursor 版本写入的 account 不一致（本机实测为 `Cursor Key`）。
    private static func readSafeStoragePassword() -> PasswordReadResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", safeStorageService, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            AppLog.warn(.credentials, "failed to launch security for Cursor Safe Storage: \(Redact.error(error))")
            return .missing
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let status = process.terminationStatus
        guard status == 0 else {
            if securityDeniedExitCodes.contains(status) { return .denied }
            AppLog.info(.credentials, "Cursor Safe Storage unavailable (security exit \(status))")
            return .missing
        }
        guard let password = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .newlines),
            !password.isEmpty
        else { return .missing }
        return .success(password)
    }

    /// 解出 `cursor-safe-storage:v1:` 后的密文，格式不符时返回 nil，不当明文继续用。
    private static func sealedCiphertext(_ value: String) -> Data? {
        guard value.utf8.count <= sealedValueLimit,
              value.hasPrefix(sealedV1Prefix),
              let blob = Data(base64Encoded: String(value.dropFirst(sealedV1Prefix.count))),
              blob.count > 3,
              blob.prefix(3) == Data("v10".utf8)
        else { return nil }
        let ciphertext = blob.dropFirst(3)
        guard ciphertext.count % kCCBlockSizeAES128 == 0 else { return nil }
        return Data(ciphertext)
    }

    static func encryptionKey(password: String) -> Data? {
        var derived = Data(count: kCCKeySizeAES128)
        let passwordBytes = Array(password.utf8)
        let salt = Data("saltysalt".utf8)
        let status = derived.withUnsafeMutableBytes { derivedBuffer -> Int32 in
            guard let derivedBase = derivedBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return Int32(kCCParamError)
            }
            return salt.withUnsafeBytes { saltBuffer -> Int32 in
                guard let saltBase = saltBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return Int32(kCCParamError)
                }
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.map { Int8(bitPattern: $0) }, passwordBytes.count,
                    saltBase, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1003,
                    derivedBase, kCCKeySizeAES128
                )
            }
        }
        return status == kCCSuccess ? derived : nil
    }

    /// 解密加密的 access token。CBC 不带完整性校验，错误的密钥也可能解出能去填充的乱码，
    /// 所以结果必须是 JWT 才返回，避免把乱码当 token 发出去。
    static func decryptAccessToken(sealedValue: String, key: Data) -> String? {
        guard let ciphertext = sealedCiphertext(sealedValue) else { return nil }
        return decryptAccessToken(ciphertext: ciphertext, key: key)
    }

    private static func decryptAccessToken(ciphertext: Data, key: Data) -> String? {
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var decryptedCount = 0
        let status = output.withUnsafeMutableBytes { outputBuffer -> Int32 in
            guard let outputBase = outputBuffer.baseAddress else { return Int32(kCCParamError) }
            return ciphertext.withUnsafeBytes { cipherBuffer -> Int32 in
                guard let cipherBase = cipherBuffer.baseAddress else { return Int32(kCCParamError) }
                return key.withUnsafeBytes { keyBuffer -> Int32 in
                    guard let keyBase = keyBuffer.baseAddress else { return Int32(kCCParamError) }
                    return iv.withUnsafeBytes { ivBuffer -> Int32 in
                        guard let ivBase = ivBuffer.baseAddress else { return Int32(kCCParamError) }
                        return CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBase, key.count,
                            ivBase,
                            cipherBase, ciphertext.count,
                            outputBase, outputBuffer.count,
                            &decryptedCount
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess,
              let token = String(data: output.prefix(decryptedCount), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              token.split(separator: ".", omittingEmptySubsequences: false).count == 3,
              JWT.decodePayload(token) != nil
        else { return nil }
        return token
    }

    private struct CursorSQLiteReader {
        let databaseURL: URL

        func value(for key: String) throws -> String? {
            do {
                return try value(for: key, immutable: false)
            } catch let failure as SQLiteReadFailure {
                guard failure.code == SQLITE_CANTOPEN, walSidecarsAreMissing else {
                    throw CursorAuthError.database(failure.message)
                }
                do {
                    return try value(for: key, immutable: true)
                } catch let fallback as SQLiteReadFailure {
                    throw CursorAuthError.database(fallback.message)
                }
            }
        }

        private func value(for key: String, immutable: Bool) throws -> String? {
            var database: OpaquePointer?
            let filename = immutable
                ? "\(databaseURL.absoluteURL.absoluteString)?immutable=1"
                : databaseURL.path
            let flags = immutable
                ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
                : SQLITE_OPEN_READONLY
            let openResult = sqlite3_open_v2(filename, &database, flags, nil)
            guard openResult == SQLITE_OK, let database else {
                let failure = sqliteFailure(database: database, resultCode: openResult)
                if let database { sqlite3_close(database) }
                throw failure
            }
            defer { sqlite3_close(database) }
            sqlite3_busy_timeout(database, CursorAuth.sqliteBusyTimeoutMilliseconds)

            let sql = "SELECT value FROM ItemTable WHERE key = ?1 LIMIT 1;"
            var statement: OpaquePointer?
            let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
            guard prepareResult == SQLITE_OK, let statement else {
                throw sqliteFailure(database: database, resultCode: prepareResult)
            }
            defer { sqlite3_finalize(statement) }

            let bindResult = sqlite3_bind_text(statement, 1, key, -1, CursorAuth.sqliteTransient)
            guard bindResult == SQLITE_OK else {
                throw sqliteFailure(database: database, resultCode: bindResult)
            }

            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                return decodeValue(statement: statement, index: 0)
            case SQLITE_DONE:
                return nil
            case let result:
                throw sqliteFailure(database: database, resultCode: result)
            }
        }

        private var walSidecarsAreMissing: Bool {
            !FileManager.default.fileExists(atPath: databaseURL.path + "-wal")
                && !FileManager.default.fileExists(atPath: databaseURL.path + "-shm")
        }

        private func decodeValue(statement: OpaquePointer, index: Int32) -> String? {
            switch sqlite3_column_type(statement, index) {
            case SQLITE_TEXT:
                guard let text = sqlite3_column_text(statement, index) else { return nil }
                return String(cString: text)
            case SQLITE_BLOB:
                guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
                return String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .utf16LittleEndian)
            default:
                return nil
            }
        }

        private func sqliteFailure(
            database: OpaquePointer?,
            resultCode: Int32
        ) -> SQLiteReadFailure {
            let code = database.map(sqlite3_errcode) ?? resultCode
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "unknown SQLite error"
            return SQLiteReadFailure(code: code, message: message)
        }
    }

    private struct SQLiteReadFailure: Error {
        let code: Int32
        let message: String
    }

    private static let sqliteTransient: sqlite3_destructor_type =
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

nonisolated enum CursorAuthError: Error, CustomStringConvertible, Equatable {
    case invalidToken(String)
    case expired
    case database(String)
    /// 登录态已加密，还没拿到读取 `Cursor Safe Storage` 的钥匙串授权：
    /// 用户拒绝过（`denied`），或还没看过授权说明 / Cursor 未开启时不主动读取。
    case keychainAccessRequired(denied: Bool)
    case keychainUnavailable
    case undecryptable

    var description: String {
        switch self {
        case .invalidToken(let message): return "invalid Cursor credential: \(message)"
        case .expired: return "Cursor credential expired; open Cursor and sign in again"
        case .database(let message): return "Cursor credential database read failed: \(message)"
        case .keychainAccessRequired(let denied):
            return denied
                ? "Cursor credential is encrypted; keychain access to Cursor Safe Storage was denied"
                : "Cursor credential is encrypted; keychain access to Cursor Safe Storage not granted yet"
        case .keychainUnavailable: return "Cursor credential is encrypted; Cursor Safe Storage keychain item unavailable"
        case .undecryptable: return "Cursor credential could not be decrypted; open Cursor and sign in again"
        }
    }
}
