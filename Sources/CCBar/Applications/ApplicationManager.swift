import Foundation
import Observation
import CCBarConfiguration

struct ApplicationVersionState {
    var status = "unchecked"
    var latestVersion: String?
    var checkedAt: Date?
    var error: String?
}

struct ApplicationOperationState {
    let id = UUID().uuidString
    let plan: ApplicationLifecyclePlan
    var status = "running"
    let startedAt = Date()
    var finishedAt: Date?
    var error: String?
    var output = ""
}

/// Lives with AppState, so native operations and their outcome survive closing the
/// React window. Discovery is read-only; mutations require a confirmed native plan.
@Observable @MainActor
final class ApplicationManager {
    let definitions: [ManagedApplicationDefinition]
    private(set) var inventory: [String: ApplicationDiscoveryResult] = [:]
    private(set) var versions: [String: ApplicationVersionState] = [:]
    private(set) var scanning = false
    private(set) var checkingVersions = false
    private(set) var lastScannedAt: Date?
    private(set) var operation: ApplicationOperationState?
    private(set) var error: String?
    private let environment: ApplicationDiscoveryEnvironment
    private let discover: @Sendable ([ManagedApplicationDefinition]) async -> [String: ApplicationDiscoveryResult]
    private let latest: @Sendable (ApplicationReleaseSource) async throws -> String
    private let run: @Sendable (ApplicationLifecyclePlan) async throws -> String
    private var scanTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var plans: [String: (ApplicationLifecyclePlan, Date)] = [:]

    init(definitions: [ManagedApplicationDefinition] = ManagedApplicationCatalog.all,
         environment: ApplicationDiscoveryEnvironment = .init(),
         discover: (@Sendable ([ManagedApplicationDefinition]) async -> [String: ApplicationDiscoveryResult])? = nil,
         latest: (@Sendable (ApplicationReleaseSource) async throws -> String)? = nil,
         run: (@Sendable (ApplicationLifecyclePlan) async throws -> String)? = nil) {
        self.definitions = definitions; self.environment = environment
        self.discover = discover ?? { await ApplicationDiscovery(environment: environment).scan($0) }
        self.latest = latest ?? { try await ApplicationVersionClient(session: NetworkProxy.currentSession()).latest(for: $0) }
        self.run = run ?? { plan in
            let execute: ApplicationCommandExecutor = { command, timeout in
                let localTool = ["/usr/bin/hdiutil", "/usr/bin/ditto", "/usr/bin/codesign"].contains(command.executable)
                guard let values = localTool ? command.environment : NetworkProxy.subprocessEnvironment(base: command.environment) else {
                    throw ApplicationLifecycleError.unavailable("当前代理无法用于安装工具，请检查代理设置。")
                }
                var command = command
                command.environment = values
                return try await ApplicationCommandRunner.run(command, timeout)
            }
            let session = plan.action == .uninstall ? URLSession.shared : try NetworkProxy.currentSession()
            return try await ApplicationLifecycleExecutor(execute: execute, session: session).run(plan)
        }
    }

    var planner: ApplicationLifecyclePlanner { ApplicationLifecyclePlanner(environment: environment) }
    var hasActiveOperation: Bool { operationTask != nil }

    func ensureScan(refresh: Bool = false) {
        guard scanTask == nil, operationTask == nil, !checkingVersions, refresh || lastScannedAt == nil else { return }
        scanning = true
        scanTask = Task { [weak self] in
            guard let self else { return }
            inventory = await discover(definitions)
            lastScannedAt = Date()
            scanning = false; scanTask = nil
        }
    }

    func checkVersions(catalogID: String?) throws {
        guard !checkingVersions, operationTask == nil else { throw busy() }
        if let catalogID, !definitions.contains(where: { $0.id == catalogID }) { throw HostWindowValidation.notFound() }
        ensureScan()
        checkingVersions = true
        checkTask = Task { [weak self] in
            guard let self else { return }
            await scanTask?.value
            let targets = definitions.filter { catalogID == nil || $0.id == catalogID }
            for definition in targets {
                for installation in inventory[definition.id]?.installations ?? [] {
                    var previous = versions[installation.id] ?? ApplicationVersionState()
                    previous.status = "checking"; previous.error = nil
                    versions[installation.id] = previous
                    do {
                        guard let source = ApplicationVersionClient.source(for: definition, installation: installation) else {
                            previous.status = "unknown"
                            previous.error = tr("The release source could not be verified.", "无法确认此安装对应的版本来源。")
                            previous.checkedAt = Date(); versions[installation.id] = previous
                            continue
                        }
                        let value = try await latest(source)
                        previous.latestVersion = value
                        if let installed = installation.version,
                           let order = ApplicationVersionClient.compare(installed: installed, latest: value) {
                            previous.status = order == .orderedAscending ? "updateAvailable" : "current"
                        } else { previous.status = "unknown" }
                        previous.error = nil
                    } catch {
                        previous.status = "failed"
                        previous.error = tr("Version check failed. Try again later.", "版本检查失败，请稍后重试。")
                    }
                    previous.checkedAt = Date(); versions[installation.id] = previous
                }
            }
            checkingVersions = false; checkTask = nil
        }
    }

    func prepare(catalogID: String, action: ApplicationLifecycleAction, installationID: String?) throws -> (String, ApplicationLifecyclePlan, Date) {
        guard !scanning, !checkingVersions, operationTask == nil, lastScannedAt != nil else { throw busy() }
        guard let definition = definitions.first(where: { $0.id == catalogID }) else { throw HostWindowValidation.notFound() }
        let installations = inventory[catalogID]?.installations ?? []
        let installation = installationID.flatMap { id in installations.first { $0.id == id } }
        guard (action == .install && installationID == nil && installations.isEmpty)
                || (action != .install && installation != nil) else { throw HostWindowValidation.invalid() }
        let plan = try planner.plan(definition, action: action, installation: installation)
        plans = plans.filter { $0.value.1 > Date() }
        let id = UUID().uuidString, expires = Date().addingTimeInterval(300)
        plans[id] = (plan, expires)
        return (id, plan, expires)
    }

    func execute(planID: String) throws {
        guard operationTask == nil, !scanning, !checkingVersions else { throw busy() }
        guard let (plan, expires) = plans.removeValue(forKey: planID), expires > Date(),
              let definition = definitions.first(where: { $0.id == plan.catalogID }) else {
            throw HostError(code: "operation_failed", message: tr("The plan expired. Review the operation again.", "操作计划已过期，请重新确认。"))
        }
        operation = ApplicationOperationState(plan: plan)
        plans.removeAll()
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let current = (await discover([definition]))[definition.id]?.installations ?? []
                let installation = plan.installation.flatMap { old in current.first { $0.id == old.id } }
                guard (plan.action == .install ? current.isEmpty : (installation != nil && installation == plan.installation)),
                      try planner.plan(definition, action: plan.action, installation: installation) == plan else {
                    throw ApplicationLifecycleError.changedInstallation
                }
                let output = try await run(plan)
                inventory = await discover(definitions)
                lastScannedAt = Date()
                let updated = inventory[definition.id]?.installations ?? []
                switch plan.action {
                case .install:
                    guard !updated.isEmpty else { throw ApplicationLifecycleError.failed(tr("The installer finished, but the application could not be verified. Detect again.", "安装程序已结束，但未能验证应用，请重新识别。")) }
                case .uninstall:
                    if let path = plan.installation?.path {
                        guard (try? FileManager.default.attributesOfItem(atPath: path)) == nil else {
                            throw ApplicationLifecycleError.failed(tr("The selected installation is still present. Detect again.", "所选安装仍然存在，请重新识别。"))
                        }
                    }
                case .upgrade:
                    guard let old = plan.installation,
                          let new = updated.first(where: { $0.path == old.path }), let version = new.version else {
                        throw ApplicationLifecycleError.failed(tr("The updated version could not be verified. Detect again.", "未能验证升级后的版本，请重新识别。"))
                    }
                    if versions[old.id]?.status == "updateAvailable", version == old.version {
                        throw ApplicationLifecycleError.failed(tr("The installer exited without changing the installed version.", "安装工具已结束，但实际版本没有变化。"))
                    }
                    versions[new.id] = ApplicationVersionState()
                }
                operation?.output = Redact.scrub(output)
                operation?.status = "succeeded"
            } catch {
                let message = Redact.scrub(error.localizedDescription)
                inventory = await discover(definitions)
                lastScannedAt = Date()
                operation?.error = message
                operation?.status = "failed"
            }
            operation?.finishedAt = Date(); operationTask = nil
        }
    }

    private func busy() -> HostError {
        HostError(code: "busy", message: tr("Wait for the current application operation to finish.", "请等待当前应用操作完成。"))
    }
}
