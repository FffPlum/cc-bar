import Foundation
import SwiftUI

// MARK: - ServiceStatus 模型与抓取
//
// 复用 Statuspage.io 公开接口:
// - OpenAI    https://status.openai.com/api/v2/status.json
// - Anthropic https://status.claude.com/api/v2/status.json
// - Cursor    https://status.cursor.com/api/v2/status.json
// - Kimi Code https://status.moonshot.cn/api/v2/components.json
// status.json 返回 status.indicator 字符串枚举:none / minor / major / critical / maintenance,
// 解析失败统一归为 .unknown。Kimi Code 聚合官方分组本身与子组件状态。
//
// 见 docs/技术实现.md "服务状态" 一节。

enum ServiceStatusIndicator: String, Sendable, Codable {
    case none
    case minor
    case major
    case critical
    case maintenance
    case unknown

    /// 弹出窗口 / 悬浮窗使用的圆点颜色;`.unknown` 由 UI 自行决定是否显示。
    var dotColor: Color {
        switch self {
        case .none: return .green
        case .minor: return .yellow
        case .major: return .orange
        case .critical: return .red
        case .maintenance: return .blue
        case .unknown: return .gray
        }
    }

    /// 默认中英文标签,在 UI 没有 description 时用作 tooltip。
    @MainActor
    var label: String {
        switch self {
        case .none: return tr("All systems normal", "运行正常")
        case .minor: return tr("Minor issue", "轻微故障")
        case .major: return tr("Major issue", "重大故障")
        case .critical: return tr("Critical outage", "严重故障")
        case .maintenance: return tr("Maintenance", "维护中")
        case .unknown: return tr("Status unknown", "状态未知")
        }
    }
}

struct ServiceStatus: Sendable, Equatable {
    var indicator: ServiceStatusIndicator
    var description: String?
    var updatedAt: Date?
    var fetchedAt: Date
}

enum ServiceStatusClient {
    static let openAIStatusURL = URL(string: "https://status.openai.com/api/v2/status.json")!
    static let anthropicStatusURL = URL(string: "https://status.claude.com/api/v2/status.json")!
    static let cursorStatusURL = URL(string: "https://status.cursor.com/api/v2/status.json")!
    static let kimiComponentsURL = URL(string: "https://status.moonshot.cn/api/v2/components.json")!
    private static let kimiCodeGroupID = "cyrtlddz0q8c"

    /// 拉取 Statuspage.io status.json 并解析为 ServiceStatus;
    /// 任何网络 / 解码错误都抛出,调用方负责保留旧快照。
    static func fetch(from url: URL) async throws -> ServiceStatus {
        let data = try await fetchData(from: url)

        struct Response: Decodable {
            struct Status: Decodable {
                let indicator: String
                let description: String?
            }
            struct Page: Decodable {
                let updatedAt: Date?
                private enum CodingKeys: String, CodingKey { case updatedAt = "updated_at" }
            }
            let page: Page?
            let status: Status
        }

        let payload = try makeDecoder().decode(Response.self, from: data)
        let indicator = ServiceStatusIndicator(rawValue: payload.status.indicator) ?? .unknown
        return ServiceStatus(
            indicator: indicator,
            description: payload.status.description,
            updatedAt: payload.page?.updatedAt,
            fetchedAt: Date()
        )
    }

    static func fetchKimiCode() async throws -> ServiceStatus {
        let data = try await fetchData(from: kimiComponentsURL)
        return try parseKimiComponents(from: data)
    }

    static func parseKimiComponents(from data: Data, fetchedAt: Date = Date()) throws -> ServiceStatus {
        struct Response: Decodable {
            struct Component: Decodable {
                let id: String
                let name: String
                let status: String
                let group: Bool?
                let groupID: String?
                let components: [String]?
                let updatedAt: Date?

                private enum CodingKeys: String, CodingKey {
                    case id, name, status, group, components
                    case groupID = "group_id"
                    case updatedAt = "updated_at"
                }
            }
            let components: [Component]
        }

        let payload = try makeDecoder().decode(Response.self, from: data)
        let groups = payload.components.filter {
            $0.id == kimiCodeGroupID && $0.name == "Kimi Code" && $0.group == true
        }
        guard groups.count == 1, let group = groups.first,
              let declaredIDs = group.components, !declaredIDs.isEmpty,
              Set(declaredIDs).count == declaredIDs.count else {
            throw URLError(.cannotParseResponse)
        }

        let declaredIDSet = Set(declaredIDs)
        let children = payload.components.filter {
            $0.group != true && ($0.groupID == group.id || declaredIDSet.contains($0.id))
        }
        guard children.count == declaredIDs.count,
              Set(children.map(\.id)) == declaredIDSet,
              children.allSatisfy({ $0.groupID == group.id }) else {
            throw URLError(.cannotParseResponse)
        }

        let indicator = ([group] + children).map { kimiIndicator(for: $0.status) }.reduce(ServiceStatusIndicator.none) {
            kimiSeverity($1) > kimiSeverity($0) ? $1 : $0
        }
        let updatedAt = ([group.updatedAt] + children.map(\.updatedAt)).compactMap { $0 }.max()
        return ServiceStatus(
            indicator: indicator,
            description: nil,
            updatedAt: updatedAt,
            fetchedAt: fetchedAt
        )
    }

    private static func fetchData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await NetworkProxy.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO8601 date: \(raw)"
            )
        }
        return decoder
    }

    private static func kimiIndicator(for status: String) -> ServiceStatusIndicator {
        switch status {
        case "operational": .none
        case "degraded_performance": .minor
        case "partial_outage": .major
        case "major_outage": .critical
        case "under_maintenance": .maintenance
        default: .unknown
        }
    }

    private static func kimiSeverity(_ indicator: ServiceStatusIndicator) -> Int {
        switch indicator {
        case .none: 0
        case .unknown: 1
        case .maintenance: 2
        case .minor: 3
        case .major: 4
        case .critical: 5
        }
    }
}
