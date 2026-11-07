# 开发协调（Codex）

## 路由契约

`window.bootstrap` 和 `window.navigate` 是 **Host API method 字符串**，通过现有 `ccbarHost` transport 请求，不是 JS 全局函数，也不新增第二套桥接。

- 后端 B 负责 bootstrap / navigate 方法及 AppState.mainTab Observation。
- 前端 C 请求 bootstrap，导航时调用 navigate；收到 `state.changed` 包含 `navigation` 后重新读 bootstrap/route。
- 容器 A 只负责持有 service、安装 transport 和资源生命周期，不需要另外注入路由函数。可以提供不依赖业务方法的 `webContent` 崩溃恢复。
- route 固定 `{page:"applications"|"application"|"quotaManagement"|"stats"|"settings", application?:string}`。

## 文件所有权

- A：React 容器、bundle scheme handler、MacOSWebKitTransport、AppDelegate 接入、Package.swift、pbxproj、资源构建/CI。
- B：MacOSHostService 与 HostWindow* 新文件、host-api SDK、必要 presenter/隔离测试；不得改 A 文件。新增 Swift 文件记入 React接口开发记录供 A / Codex 注册。
- C：packages/interface。根据 B 的 window.ts 和接口文档调用，不发明另一份接口。
- Codex：计划、审查、验证与任务反馈。尚未验收不能把 React 设为默认。

## 额外审阅发现

- 自定义 scheme 不保证 `crypto.randomUUID()` 可用；B 需为 SDK 请求 ID 做兼容处理。
- SPM `.process(Resources)` 会展平资源；A 需对 WebInterface 用 `.copy` 保留层级，同时避免重复资源条目。
- `AuthorizationStore(directory:)` 和 `ApplicationStore(defaults:)` 已有注入点，AppState 目前硬编码它们。B 对写操作的测试必须注入临时 store 或明确 fake，不能触碰用户真实配置。
- 原生业务服务有大量 SettingsStore.shared；注入测试必须验证真实写入 owner 隔离，不能只给 MacOSHostService 传一份临时 settings 就声称安全。
