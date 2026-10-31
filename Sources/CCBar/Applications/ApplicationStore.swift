import Foundation
import Observation
import CCBarConfiguration

@Observable @MainActor
final class ApplicationStore {
    private(set) var snapshots: [AgentApplication: ConfigurationSnapshot] = [:]
    private(set) var errors: [AgentApplication: String] = [:]
    private(set) var detected: Set<AgentApplication> = []
    private(set) var logins: [AgentApplication: DetectedLogin] = [:]
    private(set) var lastBackup: URL?
    private(set) var addedApplications: Set<AgentApplication>
    private let defaults: UserDefaults
    private static let addedKey = "ccbar.applications.added.v1"
    let repository = ConfigurationRepository()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        addedApplications = Set((defaults.stringArray(forKey: Self.addedKey) ?? []).compactMap(AgentApplication.init(rawValue:)))
    }

    var sidebarApplications: [AgentApplication] {
        AgentApplication.allCases.filter { detected.contains($0) && addedApplications.contains($0) }
    }

    func setAdded(_ added: Bool, application: AgentApplication) {
        if added { addedApplications.insert(application) } else { addedApplications.remove(application) }
        defaults.set(addedApplications.map(\.rawValue).sorted(), forKey: Self.addedKey)
    }

    func updateDetectedApplications(_ applications: Set<AgentApplication>) {
        detected = applications
        // Keep the existing sidebar on upgrade; subsequent additions are explicit.
        if defaults.object(forKey: Self.addedKey) == nil, !applications.isEmpty {
            addedApplications = applications
            defaults.set(addedApplications.map(\.rawValue).sorted(), forKey: Self.addedKey)
        }
    }

    func scan() {
        let clients = OnboardingClientDetection.installedClients()
        var discovered = Set(clients.compactMap { AgentApplication(rawValue: $0.rawValue) })
        for application in AgentApplication.allCases {
            do {
                logins[application] = try repository.detectedLogin(for: application)
                if logins[application] != nil { discovered.insert(application) }
            } catch { errors[application] = error.localizedDescription }
            do {
                let snapshot = try repository.read(application)
                snapshots[application] = snapshot
                errors[application] = nil
                if snapshot.hasConfiguration { discovered.insert(application) }
            } catch { errors[application] = error.localizedDescription }
            if FileManager.default.fileExists(atPath: repository.directory(for: application).path), application != .gemini {
                discovered.insert(application)
            }
        }
        updateDetectedApplications(discovered)
    }
    func select(_ native: NativeProvider) throws {
        guard let snapshot = snapshots[native.provider.application] else { throw ConfigurationError.invalidFile }
        lastBackup = try repository.apply(repository.planSelecting(native, snapshot: snapshot))
    }
    func activate(_ provider: ApplicationProvider, key: String?) throws {
        guard let snapshot = snapshots[provider.application] else { throw ConfigurationError.invalidFile }
        lastBackup = try repository.apply(repository.plan(provider: provider, credential: key, snapshot: snapshot))
    }
}

extension AgentApplication {
    var brand: ServiceBrand {
        switch self {
        case .gemini: .gemini
        case .grok: .grok
        default: ServiceBrand(rawValue: rawValue) ?? .codex
        }
    }
    var usageApp: UsageApp? { UsageApp(rawValue: rawValue) }
}

extension ModelSupplier {
    var brand: ServiceBrand? {
        switch self {
        case .openai: .codex
        case .anthropic: .claude
        case .kimi: .kimi
        case .deepseek: .deepseek
        case .grok: .grok
        case .gemini: .gemini
        case .custom: nil
        }
    }
}
