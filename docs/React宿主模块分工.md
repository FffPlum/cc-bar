# 宿主模块分工补充

为加快完整迁移，统计映射独立给本地 Kimi D，避免 B 同时承担全部业务。

## Kimi D：统计域

新增 `Sources/CCBar/Core/HostAPI/HostWindowUsageService.swift`（可拆同前缀新文件），不编辑已有 MacOSHostService、SDK、AppState 或其他任务文件。

入口固定：

```swift
@MainActor
final class HostWindowUsageService {
    static let methods: Set<String> // 下面列出的明确方法
    init(state: AppState, settings: SettingsStore)
    func handle(_ method: String, params: [String: HostJSON]) async throws -> HostJSON
}
```

负责 `window.usage.overview`、`usage.refresh`、`conversations.list`、`conversations.detail`、`projects.list`、`projects.detail`、`quota.analytics`，以及契约中具体对话 ID 复制/项目 Finder 动作。以最新 window.ts 的真实方法字符串为准，与 B 协调记录。

私有 DTO 编码、参数验证、opaque ID 映射均可在这个持久实例中完成。复用已有模型，最多提取视图中纯逻辑为新 presenter；不改其他任务的类以避免冲突。遇到访问级别必须改旧文件时记清具体 symbol 和原因，由 B/Codex协调。

返回字段严格匹配 packages/host-api/src/window.ts。B 仍负责契约更正，D 只记录类型缺口，不另造 DTO。新增测试只在独立 `HostWindowUsageTests.swift` 中，注入临时设置/安全状态；不运行构建。

## Kimi B：主分派与其他域

- 继续负责 window.ts、MacOSHostService/HostWindow* 主分派、应用/供应商/账号/设置/操作状态和全部事件。
- 初始化并持有 `HostWindowUsageService(state:settings:)`，把 D 方法集合并入能力和分派，调用其 handle。
- 不再实现 D 的统计方法，不改 D 文件。观察用量/对话/周期等 owner 并发 usage/quota 事件仍由 B 负责。
- 重新读取第一轮契约审查的第10–14项（该部分在首次阅读后追加），补全每服务 KPI、额外登录、来源/系统状态、长任务与隐私 ID 语义。

## 前端/容器

C 继续只负责 packages/interface。A 继续容器和构建，所有新增 Swift 文件最终统一注册到 Xcode。
