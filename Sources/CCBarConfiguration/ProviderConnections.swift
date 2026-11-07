import Foundation

/// One visible connection per native provider, even when that provider exposes many models.
public struct ProviderConnection: Identifiable, Sendable {
    public let id: String
    public var provider: ApplicationProvider
    public var models: [String]
    public var isActive: Bool

    public static func list(application: AgentApplication, native: [NativeProvider], saved: [ApplicationProvider]) -> [Self] {
        let native = native.filter { $0.provider.application == application }
        let saved = saved.filter { $0.application == application }
        var result: [Self] = []
        for item in native {
            let provider = saved.first { $0.id == item.id } ?? item.provider
            let id = (provider.nativeID ?? provider.id) + "|" + provider.endpoint
            if let index = result.firstIndex(where: { $0.id == id }) {
                if !provider.model.isEmpty, !result[index].models.contains(provider.model) {
                    result[index].models.append(provider.model)
                }
                result[index].isActive = result[index].isActive || item.isActive
            } else {
                result.append(Self(id: id, provider: provider, models: provider.model.isEmpty ? [] : [provider.model], isActive: item.isActive))
            }
        }
        for profile in saved where !profile.id.hasPrefix("native:") {
            let nativeID = profile.nativeID ?? "ccbar-" + profile.id.lowercased()
            if native.contains(where: { $0.provider.nativeID == nativeID && $0.provider.endpoint == profile.endpoint && $0.provider.model == profile.model }) { continue }
            result.append(Self(id: profile.id, provider: profile, models: profile.model.isEmpty ? [] : [profile.model], isActive: false))
        }
        return result
    }
}
