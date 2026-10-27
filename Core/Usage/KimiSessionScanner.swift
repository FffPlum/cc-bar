import CryptoKit
import Foundation

/// 只读 Kimi Code CLI 的本机会话日志，统一汇总为 `UsageApp.kimi` 用量。
///
/// 两个版本共用 share 根布局（`defaultRoots()` 返回 `~/.kimi-code` 与 `~/.kimi`）：
/// - 新版（JS，`~/.kimi-code/sessions/<workspace>/session_<id>/`）：每个 agent 一份
///   `agents/<agent>/wire.jsonl`。请求级用量在 `usage.record` 行
///   （`usage = {inputOther, output, inputCacheRead, inputCacheCreation}`，`time` 为 Unix 毫秒；
///   `inputOther` 已排除缓存，不能再减）。同一 session 的 main / 子代理文件合并为一个对话，
///   父文件里的 `subagent.completed` 是子代理用量汇总，忽略——子代理自己的 `usage.record`
///   按请求计。fork 会把源会话的记录原样复制进新文件（末尾追加 `forked` 行），
///   用「模型 + 时间 + 四项 token」的内容签名跨会话去重。
/// - 旧版（Python，`~/.kimi/sessions/<md5>/<session>/`）：单文件 `wire.jsonl`，
///   行格式 `{timestamp(秒), message:{type, payload}}`。用量在 `StatusUpdate` 的
///   `token_usage`（`input_other` 已排除缓存）；子代理事件以 `SubagentEvent` 嵌套在
///   父文件里（递归展开）；同时读取 `subagents/<id>/wire.jsonl`，存在独立文件时跳过对应镜像。
///   `context_tokens` / `context_usage` 是上下文占用，不计。旧版日志没有模型字段，
///   模型记 `unknown`、费用未定价；fork 复制按 `message_id` 去重。
///
/// 增量口径与 Antigravity 一致：按会话记录每个 wire 文件的 (size, mtime) 签名，
/// 任一文件变化即整段重读该会话、调用方用完整贡献替换；读取失败保留旧签名与旧贡献；
/// 源日志删除的会话保留历史（签名留在 State 里，fork 副本仍会去重）。
/// 仅提取标题、项目与用量，不持久化消息正文；末尾未写完的半行不消费。
nonisolated enum KimiSessionScanner {
    nonisolated struct FileSignature: Sendable, Codable, Equatable {
        var size: Int64
        var mtime: Double
        var identity: ScanFileIdentity? = nil
    }

    nonisolated struct State: Sendable, Codable, Equatable {
        static let currentVersion = 2
        var version = Self.currentVersion
        /// 会话 ID → wire 文件路径 → 读取时签名。全部文件签名一致时会话不重读。
        var conversations: [String: [String: FileSignature]] = [:]
        /// 会话 ID → 已计入用量事件的内容签名：fork / 复制重放去重；
        /// 会话重读时先整体撤下旧签名再补新，删除的会话保留签名继续压制副本。
        var seenByConversation: [String: [String]] = [:]
        /// 仅保留规范化的请求用量，不含正文。某个子代理日志被清理后仍可保留其贡献。
        var fileEvents: [String: [String: [StoredEvent]]] = [:]

        // 字段缺失（旧快照 / 部分写入）按空值解码；version 缺失视为 0，与当前版本不符即整段重扫。
        nonisolated init() {}

        nonisolated init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
            conversations = try container.decodeIfPresent(
                [String: [String: FileSignature]].self, forKey: .conversations
            ) ?? [:]
            seenByConversation = try container.decodeIfPresent(
                [String: [String]].self, forKey: .seenByConversation
            ) ?? [:]
            fileEvents = try container.decodeIfPresent(
                [String: [String: [StoredEvent]]].self, forKey: .fileEvents
            ) ?? [:]
        }
    }

    nonisolated struct Result: Sendable {
        /// 本轮刷新会话的完整贡献，不能作为新增条目累加。
        var entries: [UsageEntry] = []
        var conversationSeeds: [ConversationSeed] = []
        var refreshedConversationIDs: Set<String> = []
        var newState: State?
        var filesRead = 0
        /// 读取失败的 wire 文件数；失败会话保留旧贡献与旧签名。
        var failedFileCount = 0
        var isComplete = false
    }

    /// 两个版本的 share 根。`KIMI_SHARE_DIR` 设置时旧版以它为准（与旧 CLI 一致）。
    static func defaultRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots = [home.appendingPathComponent(".kimi-code", isDirectory: true)]
        let env = ProcessInfo.processInfo.environment["KIMI_SHARE_DIR"]
        let legacy: URL
        if let env, !env.isEmpty {
            legacy = URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            legacy = home.appendingPathComponent(".kimi", isDirectory: true)
        }
        if !roots.contains(where: { $0.path == legacy.path }) {
            roots.append(legacy)
        }
        return roots
    }

    static func scan(
        previous: State?,
        roots: [URL],
        force: Bool = false,
        onProgress: ScanProgressCallback? = nil
    ) -> Result {
        let isTimingUpgrade = previous?.version == 1
        let baseline = previous.flatMap {
            $0.version == State.currentVersion || isTimingUpgrade ? $0 : nil
        }
        var state = baseline ?? State()
        if isTimingUpgrade { state.version = State.currentVersion }
        var result = Result()
        let diskSessions = discoverSessions(roots: roots, failedCount: &result.failedFileCount)
        let legacyWorkDirs = legacyWorkDirMap(roots: roots)
        var projectResolver = ConversationProjectResolver()

        for (index, session) in diskSessions.enumerated() {
            onProgress?(ScanProgress(
                app: .kimi,
                filesCompleted: index,
                filesTotal: diskSessions.count,
                linesParsed: result.filesRead
            ))
            var signatures: [String: FileSignature] = [:]
            var signatureComplete = true
            let metadataFiles = [session.directory.appendingPathComponent("state.json"),
                                 session.directory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                                    .appendingPathComponent("kimi.json")]
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            for url in session.files + metadataFiles {
                guard let signature = Self.signature(of: url) else {
                    signatureComplete = false
                    continue
                }
                signatures[url.path] = signature
            }
            guard signatureComplete else {
                result.failedFileCount += 1
                continue
            }
            let livePaths = Set(session.files.map(\.path))
            let retained = state.fileEvents[session.id] ?? [:]
            // 单个子代理文件删除也保留其贡献与签名；现存文件追加时继续正常采集。
            for (path, oldSignature) in baseline?.conversations[session.id] ?? [:]
            where path.hasSuffix("/wire.jsonl") && !livePaths.contains(path) && retained[path] != nil {
                signatures[path] = oldSignature
            }
            // v1 → v2 保留全部旧账本，但现存文件必须重读以补齐原生计时。
            guard force || isTimingUpgrade || signatures != baseline?.conversations[session.id] else { continue }

            let read = readSession(session)
            result.filesRead += read.readPaths.count
            result.failedFileCount += read.failedCount
            // 任一文件读失败：保留旧签名、旧去重记录与旧贡献，下一轮整段重试。
            guard read.failedCount == 0, !read.readPaths.isEmpty else { continue }

            // fork / 复制去重：已归属其他会话（含已删除会话保留的签名）的事件不计，
            // 本会话内部重复（同签名）也只计一次。
            var ownedByOthers = Set<String>()
            for (owner, signatures) in state.seenByConversation where owner != session.id {
                ownedByOthers.formUnion(signatures)
            }
            let preservedEvents = retained.keys.sorted().filter { !livePaths.contains($0) }
                .flatMap { retained[$0] ?? [] }
            var ownSignatures = Set<String>()
            var entries: [UsageEntry] = []
            for event in preservedEvents + read.events
            where !ownedByOthers.contains(event.signature) && ownSignatures.insert(event.signature).inserted {
                entries.append(makeEntry(conversationID: session.id, event: event))
            }
            state.conversations[session.id] = signatures
            state.seenByConversation[session.id] = ownSignatures.sorted()
            var fileEvents = retained
            for (path, events) in read.eventsByFile { fileEvents[path] = events }
            state.fileEvents[session.id] = fileEvents
            // 新发现的空会话 / 纯 fork 副本只保存进度；已有贡献变空时必须通知调用方清桶。
            guard !entries.isEmpty || !(baseline?.seenByConversation[session.id] ?? []).isEmpty else { continue }
            result.entries.append(contentsOf: entries)
            result.refreshedConversationIDs.insert(session.id)

            let metadata = sessionMetadata(session, legacyWorkDirs: legacyWorkDirs)
            result.conversationSeeds.append(ConversationSeed(
                key: "kimi:\(session.id)",
                id: session.id,
                app: .kimi,
                title: metadata.title ?? read.fallbackTitle,
                project: projectResolver.resolve(rawPath: metadata.cwd ?? "", source: .cwd),
                gitBranch: nil,
                sourcePath: session.files[0].path,
                includesSubtasks: read.includesSubtasks || fileEvents.count > 1,
                cacheCreationAvailable: true
            ))
        }

        result.isComplete = result.failedFileCount == 0
        // 升级中任何来源失败都保留 v1 进度，下轮继续强制重读；成功会话只替换贡献，不会累加。
        result.newState = isTimingUpgrade && !result.isComplete ? previous : state
        return result
    }

    // MARK: - 会话发现

    private nonisolated enum Layout {
        /// 新版：agents/<agent>/wire.jsonl，一个会话多份文件。
        case kimiCodeAgents
        /// 旧版：会话主日志与独立子代理日志，父日志转发事件按 agent_id 排除镜像。
        case legacyWire
    }

    private nonisolated struct SessionOnDisk: Sendable {
        var id: String
        var layout: Layout
        var files: [URL]
        var directory: URL
        var createdAt: Double
        var workspaceSegment: String
    }

    /// 不存在的目录视为未安装；存在但不可读必须报告失败，不能当作成功的空扫描。
    private static func directoryContents(_ url: URL, failedCount: inout Int) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }
        do {
            return try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ).sorted { $0.path < $1.path }
        } catch {
            failedCount += 1
            return []
        }
    }

    private static func discoverSessions(roots: [URL], failedCount: inout Int) -> [SessionOnDisk] {
        let fileManager = FileManager.default
        var sessions: [SessionOnDisk] = []
        var seenIDs = Set<String>()
        for root in roots {
            let workspaces = directoryContents(root.appendingPathComponent("sessions"), failedCount: &failedCount)
            for workspace in workspaces {
                for directory in directoryContents(workspace, failedCount: &failedCount) {
                    let agentsDirectory = directory.appendingPathComponent("agents", isDirectory: true)
                    let legacyWire = directory.appendingPathComponent("wire.jsonl", isDirectory: false)
                    var files: [URL] = []
                    let layout: Layout
                    if fileManager.fileExists(atPath: agentsDirectory.path) {
                        for agent in directoryContents(agentsDirectory, failedCount: &failedCount) {
                            files.append(contentsOf: directoryContents(agent, failedCount: &failedCount)
                                .filter { $0.lastPathComponent == "wire.jsonl" })
                        }
                        layout = .kimiCodeAgents
                    } else {
                        if fileManager.fileExists(atPath: legacyWire.path) { files.append(legacyWire) }
                        for agent in directoryContents(directory.appendingPathComponent("subagents"), failedCount: &failedCount) {
                            files.append(contentsOf: directoryContents(agent, failedCount: &failedCount)
                                .filter { $0.lastPathComponent == "wire.jsonl" })
                        }
                        layout = .legacyWire
                    }
                    guard !files.isEmpty else { continue }
                    let name = directory.lastPathComponent
                    guard !name.isEmpty, seenIDs.insert(name).inserted else { continue }
                    let metadata = (try? Data(contentsOf: directory.appendingPathComponent("state.json")))
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    let attributes = try? fileManager.attributesOfItem(atPath: directory.path)
                    let born = (attributes?[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    let createdAt = (metadata?["createdAt"] as? NSNumber)?.doubleValue ?? born * 1000
                    sessions.append(SessionOnDisk(id: name, layout: layout, files: files,
                                                  directory: directory, createdAt: createdAt,
                                                  workspaceSegment: workspace.lastPathComponent))
                }
            }
        }
        // 首次采集按真实创建顺序归属继承记录，避免随机 UUID 排序使 fork 抢占原会话。
        return sessions.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
    }

    private static func signature(of url: URL) -> FileSignature? {
        guard FileManager.default.isReadableFile(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return nil }
        return FileSignature(
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            mtime: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            identity: ScanFileIdentity.read(atPath: url.path)
        )
    }

    /// 旧版 `kimi.json` 的 work_dirs 表：md5(cwd) → cwd，用于项目归属。
    private static func legacyWorkDirMap(roots: [URL]) -> [String: String] {
        var map: [String: String] = [:]
        for root in roots {
            let url = root.appendingPathComponent("kimi.json", isDirectory: false)
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let workDirs = object["work_dirs"] as? [[String: Any]]
            else { continue }
            for workDir in workDirs {
                guard let path = workDir["path"] as? String else { continue }
                let digest = Insecure.MD5.hash(data: Data(path.utf8))
                    .map { String(format: "%02x", $0) }
                    .joined()
                map[digest] = path
            }
        }
        return map
    }

    // MARK: - 读取

    nonisolated struct StoredEvent: Sendable, Codable, Equatable {
        /// 内容签名：`usage.record` 为「模型|毫秒时间|四项 token」，`StatusUpdate` 为 message_id。
        var signature: String
        var timestamp: Date
        var model: String
        var input: Int
        var output: Int
        var cacheRead: Int
        var cacheCreation: Int
        var timing: RequestTiming? = nil
    }

    private nonisolated struct SessionRead: Sendable {
        var events: [StoredEvent] = []
        var eventsByFile: [String: [StoredEvent]] = [:]
        var readPaths: [String] = []
        var failedCount = 0
        var includesSubtasks = false
        var fallbackTitle: String? = nil
    }

    private nonisolated struct ModelContext {
        var request: String?
        var requestAlias: String?
        var bound: String?
    }

    private nonisolated struct TokenUsage: Hashable {
        var input: Int
        var output: Int
        var cacheRead: Int
        var cacheCreation: Int

        init(input: Int, output: Int, cacheRead: Int, cacheCreation: Int) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheCreation = cacheCreation
        }

        init?(_ object: [String: Any]?) {
            guard let object,
                  let input = tokenInteger(object["inputOther"]),
                  let output = tokenInteger(object["output"]),
                  let cacheRead = tokenInteger(object["inputCacheRead"], missing: 0),
                  let cacheCreation = tokenInteger(object["inputCacheCreation"], missing: 0)
            else { return nil }
            self.init(input: input, output: output, cacheRead: cacheRead, cacheCreation: cacheCreation)
        }
    }

    private nonisolated struct StepKey: Hashable {
        var agent: String
        var turnID: String
        var step: Int
    }

    private nonisolated struct LoopRequest {
        var usageIndices: [Int] = []
        var isRetry = false
    }

    private nonisolated struct StepContext {
        var uuid: String
        var agent: String
        var requests: [String: LoopRequest] = [:]
        var isAmbiguous = false
    }

    private nonisolated struct AgentTimingContext {
        var activeStep: StepKey?
        var acceptsUsage = false
    }

    private nonisolated struct TimingContext {
        var steps: [StepKey: StepContext] = [:]
        var agents: [String: AgentTimingContext] = [:]
    }

    private static func readSession(_ session: SessionOnDisk) -> SessionRead {
        var read = SessionRead()
        let independentAgents = Set(session.files.filter {
            $0.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "subagents"
        }.map { $0.deletingLastPathComponent().lastPathComponent })
        read.includesSubtasks = session.files.count > 1 || !independentAgents.isEmpty
        for url in session.files {
            let eventStart = read.events.count
            var context = ModelContext()
            var timing = TimingContext()
            var seen = Set<String>()
            var corrupt = false
            let outcome = JSONLLineReader.streamLines(url: url, fromOffset: 0) { batch in
                for line in batch {
                    guard let data = line.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        corrupt = true
                        continue
                    }
                    switch session.layout {
                    case .kimiCodeAgents:
                        parseKimiCodeRecord(object, into: &read, context: &context, timing: &timing)
                    case .legacyWire:
                        guard let message = object["message"] as? [String: Any],
                              let type = message["type"] as? String else { continue }
                        collectLegacyEvent(type: type, payload: message["payload"],
                                           timestamp: (object["timestamp"] as? NSNumber)?.doubleValue ?? 0,
                                           read: &read, seen: &seen, independentAgents: independentAgents, depth: 0)
                    }
                }
            }
            if case .success = outcome, !corrupt {
                read.readPaths.append(url.path)
                read.eventsByFile[url.path] = Array(read.events.dropFirst(eventStart))
            } else {
                read.failedCount += 1
            }
        }
        return read
    }

    /// 新版 wire：`usage.record` 为请求级用量；`llm.request` / `profile.bind` /
    /// `config.update` 提供模型回退。`token_counting.*` 是上下文占用，忽略。
    private static func parseKimiCodeRecord(
        _ object: [String: Any], into read: inout SessionRead,
        context: inout ModelContext, timing: inout TimingContext
    ) {
        let record: [String: Any]
        if object["type"] as? String == "context.append_loop_event",
           var event = object["event"] as? [String: Any] {
            if event["agentId"] == nil { event["agentId"] = object["agentId"] }
            record = event
        } else {
            record = object
        }
        guard let type = record["type"] as? String else { return }
        let agent = nonEmpty(record["agentId"] as? String) ?? "main"
        switch type {
        case "step.begin":
            guard let uuid = nonEmpty(record["uuid"] as? String),
                  let key = stepKey(record, agent: agent) else { return }
            if timing.steps[key] == nil {
                timing.steps[key] = StepContext(uuid: uuid, agent: agent)
            } else {
                timing.steps[key]?.isAmbiguous = true
            }
        case "llm.request":
            context.request = nonEmpty(record["model"] as? String)
            context.requestAlias = nonEmpty(record["modelAlias"] as? String)
            guard record["kind"] as? String == "loop",
                  let turnStep = nonEmpty(record["turnStep"] as? String),
                  let key = stepKey(turnStep, agent: agent), timing.steps[key]?.agent == agent else {
                timing.agents[agent] = AgentTimingContext()
                return
            }
            if timing.steps[key]?.requests[agent] == nil {
                timing.steps[key]?.requests[agent] = LoopRequest()
            } else {
                timing.steps[key]?.requests[agent]?.isRetry = true
            }
            timing.agents[agent] = AgentTimingContext(activeStep: key, acceptsUsage: true)
        case "step.end":
            guard let uuid = nonEmpty(record["uuid"] as? String),
                  let key = stepKey(record, agent: agent),
                  let step = timing.steps.removeValue(forKey: key),
                  step.uuid == uuid, step.agent == agent, !step.isAmbiguous,
                  step.requests.values.allSatisfy({ !$0.isRetry }),
                  let endUsage = TokenUsage(record["usage"] as? [String: Any]),
                  let firstTokenMs = finiteNumber(record["llmFirstTokenLatencyMs"]),
                  let generationMs = finiteNumber(record["llmStreamDurationMs"]),
                  let requestTiming = RequestTiming(
                    measuredFirstTokenMs: firstTokenMs, generationMs: generationMs
                  ) else { return }
            let candidates = step.requests.values.flatMap(\.usageIndices)
            guard candidates.count == 1, let index = candidates.first,
                  tokenUsage(read.events[index]) == endUsage else { return }
            read.events[index].timing = requestTiming
        case "profile.bind", "config.update":
            if let model = nonEmpty(record["modelAlias"] as? String) {
                context.bound = model
                context.request = nil
                context.requestAlias = nil
            }
        case "turn.prompt":
            if read.fallbackTitle == nil {
                read.fallbackTitle = ConversationTitleIndex.clean(record["input"] as? String)
            }
        case "usage.record":
            guard let usage = record["usage"] as? [String: Any] else { return }
            let input = intValue(usage["inputOther"])
            let output = intValue(usage["output"])
            let cacheRead = intValue(usage["inputCacheRead"])
            let cacheCreation = intValue(usage["inputCacheCreation"])
            guard input + output + cacheRead + cacheCreation > 0,
                  let timeMs = (record["time"] as? NSNumber)?.doubleValue,
                  timeMs.isFinite, timeMs > 0, timeMs < 253_402_300_799_000 else { return }
            let recordedModel = nonEmpty(record["model"] as? String)
            let model: String
            if let recordedModel, recordedModel == context.requestAlias, let actual = context.request,
               Pricing.pricingKey(model: recordedModel) != Pricing.pricingKey(model: actual) {
                // 同一历史请求的 API 模型优先于用户自定义别名，不读取今天的配置来推断。
                model = actual
            } else {
                model = recordedModel ?? context.request ?? context.bound ?? "unknown"
            }
            read.events.append(StoredEvent(
                signature: "u|\(model)|\(Int64(timeMs))|\(input)|\(output)|\(cacheRead)|\(cacheCreation)",
                timestamp: Date(timeIntervalSince1970: timeMs / 1000), model: model,
                input: input, output: output, cacheRead: cacheRead, cacheCreation: cacheCreation
            ))
            let index = read.events.count - 1
            guard let agentContext = timing.agents[agent], agentContext.acceptsUsage,
                  let key = agentContext.activeStep, timing.steps[key]?.requests[agent] != nil else { return }
            guard TokenUsage(usage) != nil else {
                timing.steps[key]?.isAmbiguous = true
                return
            }
            timing.steps[key]?.requests[agent]?.usageIndices.append(index)
        default:
            return
        }
    }

    private static func stepKey(_ object: [String: Any], agent: String) -> StepKey? {
        guard let turnID = nonEmpty(object["turnId"] as? String),
              let step = integer(object["step"]) else { return nil }
        return StepKey(agent: agent, turnID: turnID, step: step)
    }

    private static func stepKey(_ turnStep: String, agent: String) -> StepKey? {
        let parts = turnStep.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, let step = Int(parts[1]) else { return nil }
        return StepKey(agent: agent, turnID: String(parts[0]), step: step)
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return Int(number.stringValue)
        }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func tokenInteger(_ value: Any?, missing: Int? = nil) -> Int? {
        guard let value else { return missing }
        guard let integer = integer(value), integer >= 0, integer <= Int.max / 8 else { return nil }
        return integer
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    private static func tokenUsage(_ event: StoredEvent) -> TokenUsage {
        TokenUsage(input: event.input, output: event.output,
                   cacheRead: event.cacheRead, cacheCreation: event.cacheCreation)
    }

    private static func collectLegacyEvent(
        type: String,
        payload: Any?,
        timestamp: Double,
        read: inout SessionRead,
        seen: inout Set<String>,
        independentAgents: Set<String>,
        depth: Int
    ) {
        guard depth < 8 else { return }
        switch type {
        case "SubagentEvent":
            read.includesSubtasks = true
            guard let payload = payload as? [String: Any],
                  let event = payload["event"] as? [String: Any],
                  let eventType = event["type"] as? String
            else { return }
            if let agentID = payload["agent_id"] as? String, independentAgents.contains(agentID) { return }
            collectLegacyEvent(
                type: eventType,
                payload: event["payload"],
                timestamp: timestamp,
                read: &read,
                seen: &seen,
                independentAgents: independentAgents,
                depth: depth + 1
            )
        case "TurnBegin":
            if read.fallbackTitle == nil,
               let payload = payload as? [String: Any],
               let input = payload["user_input"] as? String {
                read.fallbackTitle = ConversationTitleIndex.clean(input)
            }
        case "StatusUpdate":
            guard let payload = payload as? [String: Any],
                  let usage = payload["token_usage"] as? [String: Any]
            else { return }
            let input = intValue(usage["input_other"])
            let output = intValue(usage["output"])
            let cacheRead = intValue(usage["input_cache_read"])
            let cacheCreation = intValue(usage["input_cache_creation"])
            guard input + output + cacheRead + cacheCreation > 0 else { return }
            guard timestamp.isFinite, timestamp > 0, timestamp < 253_402_300_799 else { return }
            let signature: String
            if let messageID = nonEmpty(payload["message_id"] as? String) {
                signature = "id|\(messageID)"
            } else {
                signature = "c|\(timestamp)|\(input)|\(output)|\(cacheRead)|\(cacheCreation)"
            }
            guard seen.insert(signature).inserted else { return }
            read.events.append(StoredEvent(
                signature: signature,
                timestamp: Date(timeIntervalSince1970: timestamp),
                model: "unknown",
                input: input,
                output: output,
                cacheRead: cacheRead,
                cacheCreation: cacheCreation
            ))
        default:
            return
        }
    }

    // MARK: - 元数据与条目

    private nonisolated struct SessionMetadata: Sendable {
        var title: String?
        var cwd: String?
    }

    private static func sessionMetadata(
        _ session: SessionOnDisk,
        legacyWorkDirs: [String: String]
    ) -> SessionMetadata {
        var metadata = SessionMetadata()
        let stateURL = session.directory.appendingPathComponent("state.json", isDirectory: false)
        let state = (try? Data(contentsOf: stateURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        switch session.layout {
        case .kimiCodeAgents:
            // state.json：自动标题与 cwd；缺失时不影响用量。
            if let state {
                metadata.title = ConversationTitleIndex.clean(state["title"] as? String)
                metadata.cwd = nonEmpty(state["cwd"] as? String)
            }
        case .legacyWire:
            // cwd 从根 kimi.json 的 work_dirs（md5(path) → path）反查；标题用自定义或首条输入。
            metadata.cwd = legacyWorkDirs[session.workspaceSegment]
            if let state, let custom = ConversationTitleIndex.clean(state["custom_title"] as? String) {
                metadata.title = custom
            }
        }
        return metadata
    }

    /// 从已提交的规范化事件还原全部请求贡献，供周期重建复用，不再读取会话正文。
    /// `seenByConversation` 是 fork / 复制去重后的所有权账本；文件事件还要经过它过滤，
    /// 才能保留已删除文件贡献，同时不把继承副本再计一次。
    static func committedEntries(from state: State) -> [UsageEntry] {
        guard state.version == State.currentVersion else { return [] }
        var seen = Set<String>()
        var committed: [(conversationID: String, event: StoredEvent)] = []
        for conversationID in state.fileEvents.keys.sorted() {
            let allowed = Set(state.seenByConversation[conversationID] ?? [])
            guard let files = state.fileEvents[conversationID] else { continue }
            for path in files.keys.sorted() {
                for event in files[path] ?? []
                where allowed.contains(event.signature) && seen.insert(event.signature).inserted {
                    committed.append((conversationID, event))
                }
            }
        }
        return committed.sorted { lhs, rhs in
            if lhs.event.timestamp != rhs.event.timestamp { return lhs.event.timestamp < rhs.event.timestamp }
            if lhs.conversationID != rhs.conversationID { return lhs.conversationID < rhs.conversationID }
            return lhs.event.signature < rhs.event.signature
        }.map { makeEntry(conversationID: $0.conversationID, event: $0.event) }
    }

    private static func makeEntry(conversationID: String, event: StoredEvent) -> UsageEntry {
        let total = event.input + event.output + event.cacheRead + event.cacheCreation
        let breakdown = Pricing.resolveCostBreakdown(
            app: .kimi,
            model: event.model,
            speed: .standard,
            input: event.input,
            output: event.output,
            cacheRead: event.cacheRead,
            cacheCreation: event.cacheCreation,
            totalTokens: total,
            reportedCost: nil,
            reportedBreakdown: nil,
            at: event.timestamp,
            inputTotal: event.input + event.cacheRead + event.cacheCreation
        )
        return UsageEntry(
            app: .kimi,
            conversationKey: "kimi:\(conversationID)",
            model: event.model,
            speed: .standard,
            day: UsageDay.startOfDay(for: event.timestamp),
            timestamp: event.timestamp,
            inputTokens: event.input,
            outputTokens: event.output,
            cacheReadTokens: event.cacheRead,
            cacheCreationTokens: event.cacheCreation,
            requestCount: 1,
            costUSD: breakdown?.total,
            costBreakdown: breakdown,
            timing: event.timing
        )
    }

    private static func intValue(_ value: Any?) -> Int {
        let raw: Int?
        if let number = value as? NSNumber {
            raw = number.intValue
        } else if let string = value as? String {
            raw = Int(string)
        } else {
            raw = nil
        }
        return raw.map { $0 >= 0 && $0 <= Int.max / 8 ? $0 : 0 } ?? 0
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let string, !string.isEmpty else { return nil }
        return string
    }
}
