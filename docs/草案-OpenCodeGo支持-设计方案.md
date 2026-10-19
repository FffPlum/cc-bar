# 草案 · OpenCode Go 支持（额度）

> 状态：**2026-10-19 修订，按本版实施**。上一版草案写于 Antigravity、Command Code 接入和服务拖拽排序之前，与当前代码有 5 处出入，本版按当前代码和 Command Code 的接入方式修订：
>
> 1. 服务顺序：排在 Command Code 之后，用户可在「设置 → 服务与账号」拖拽调整（原文为 Codex → Claude → Cursor → Go）。
> 2. 展示位：与其他额度服务一致，进入菜单栏和悬浮窗（原文为不进入）。
> 3. 凭据：复用 Command Code 的「自动读取 + 手动 API Key（钥匙串）」方式，自动读取增加 Pi 的 `auth.json`（原文只读 OpenCode `auth.json` 与环境变量，不支持手动 key）。
> 4. 状态色：按当前三档（剩余 `>=20%` 中性灰、`<20%` 橙、`=0` 红），不再是四档。
> 5. `QuotaProviderDescriptor` 已有 `supportsMenuBar` / `supportsFloatingHUD` / `showsCost` 能力字段，无需新增。
>
> 另按现有接入方式简化了两处：失败处理统一走 `QuotaError` 与「失败保留已有快照」，不再单设「不可用」状态和隐藏旧数字；首次启动引导页不加 OpenCode Go 行（见 §1.3）。
>
> 注意与已落地的 `Core/Usage/OpencodeScanner.swift` 区分：后者扫描本机 `~/.local/share/opencode/opencode.db`，属于**用量统计**；本文是 OpenCode Go **订阅额度**，两者互不影响。

## 1. 背景、目标与范围

### 1.1 用户诉求

在 cc-bar 中展示 OpenCode Go 订阅的剩余额度，形态与 Command Code 一致：设置里一个服务行（开关 + 凭据设置），Popover、菜单栏、悬浮窗按用户开关展示。

### 1.2 第一版范围

- **额度 Provider**：新增 `QuotaApp.opencodeGo`，显示 5 小时 / 周 / 月三个窗口的剩余比例。
- **Popover / 菜单栏 / 悬浮窗**：与 Command Code 相同，开启后出现；不展示费用，不展示服务状态点。
- **设置 → 服务与账号**：新增 OpenCode Go 行，含「填写凭据…」入口和凭据面板（自动读取 / 手动 API Key）；首次默认关闭。
- **额度提醒**：三个窗口接入现有低额度通知；月窗口按「计费周期」开关控制。
- **诊断**：凭据来源偏好与检测结果进入诊断导出和日志，均脱敏。

### 1.3 第一版不做

- 不进入主窗口统计（Overview / 对话 / 项目 / 额度 Timeline / Cycles）。Go 端点没有历史用量，也不写额度历史和周期。
- 不改本地用量链路：OpenCode / Pi 对话里的 `opencode-go/<model-id>` 仍按现有 `ModelProvider.opencodeGo` 归并、按本地日志计费。
- 不读浏览器 Cookie，不调用 OpenCode Console 内部接口，不用本地消费按 $12 / $30 / $60 估算剩余比例（CodexBar 有这两条备用来源，见 §2.4）。
- 首次启动引导页不加 OpenCode Go 行：引导页账号列表按 5 行在 520pt 高的窗口里排版，加第 6 行需要重新排版，单独评估。用户可在设置里看到检测结果并开启。
- 不新增 logo 资源，复用现有 `opencode` 图标，缺失时显示字母 `G`。

## 2. 调研结论

### 2.1 远端接口

OpenCode Go 是 OpenCode 的 $10/月订阅，按美元额度设三个窗口：5 小时 $12、每周 $30、每月 $60。

**端点**：`GET https://opencode.ai/zen/go/v1/usage`，`Authorization: Bearer <API key>`。

**响应**：

```json
{
  "usage": {
    "rolling": { "status": "ok", "percent": 4, "resetsAt": "2026-08-13T16:27:38.287Z" },
    "weekly":  { "status": "ok", "percent": 3, "resetsAt": "2026-08-17T00:00:00.287Z" },
    "monthly": { "status": "rate-limited", "percent": 100, "resetsAt": "2026-09-13T06:06:01.287Z" }
  }
}
```

- `percent` 是**已用**比例，单位 0～100（`0.5` 表示 0.5%）。
- `status == "rate-limited"` 表示该窗口已用完，按 100% 已用处理。
- `resetsAt` 为 UTC ISO8601，可能带毫秒。
- 401 = key 无效；403（响应含 `EntitlementError`）= key 没有 Go 订阅。
- 端点只返回当前窗口，没有历史。官方文档写明了三档限额，但没有把该端点列为公开 API，按非公开接口容错处理。

### 2.2 交叉验证来源

三个独立来源一致：

| 来源 | 内容 |
|---|---|
| OpenCode 官方服务端源码 `packages/console/app/src/routes/zen/go/v1/usage.ts`（[PR #16513](https://github.com/anomalyco/opencode/pull/16513)） | 端点、字段、`percent` 为已用 |
| CodexBar `Sources/CodexBarCore/Providers/OpenCodeGo/OpenCodeGoUsageFetcher.swift` | 同一端点与 Bearer；`percent` 按 0～100 解析；401 / 403 视为凭据无效 |
| Pi 扩展 `pi-model-selector` 的 `docs/opencode-go.md` | 同一端点；凭据取 Pi 的 `opencode-go` provider key、`OPENCODE_API_KEY` 或 `auth.json` 的 `opencode-go` 项（`key` / `access` / `apiKey`）；`rate-limited` 按 100% |

### 2.3 本地凭据位置

- OpenCode：`$XDG_DATA_HOME/opencode/auth.json`，未设置时 `~/.local/share/opencode/auth.json`，取顶层 `"opencode-go"` 项的 `key`。
- Pi：`~/.pi/agent/auth.json`，取 `"opencode-go"` 项。
- 环境变量：`OPENCODE_API_KEY`。从 Finder 启动的 App 通常拿不到终端里设置的环境变量。

```json
{ "opencode-go": { "type": "api", "key": "sk-..." } }
```

key 长期有效，不需要刷新。

### 2.4 不采用的竞品做法

CodexBar 另有两条来源，本版不采用：

- **浏览器 Cookie + Console 内部接口**：需要读取浏览器 Cookie（涉及钥匙串授权），并依赖网页内部的 server function ID，网站改版即失效。
- **本机 SQLite 估算**：用本机 `opencode-go` 消费按 $12 / $30 / $60 推算百分比。它只统计这台设备，CodexBar 自己也标为估算、说明不能据此判断账号余量。cc-bar 的额度只展示服务端数据。

## 3. 凭据方案

与 Command Code 相同的结构，新增 `OpenCodeGoAuth`：

**来源偏好**（`SettingsStore.opencodeGoCredentialPreference`，默认自动）：

- **自动**：依次读取 OpenCode `auth.json` → Pi `auth.json` → `OPENCODE_API_KEY` → 钥匙串里手动保存的 key。
- **手动 API Key**：只读钥匙串（service `com.nanvon.ccbar.opencode-go`），在凭据面板中粘贴保存，可清除。

**校验**：去除首尾空白后至少 10 个字符、只含可打印 ASCII，沿用 `CommandCodeAuth.sanitizeToken` 的规则。

**账号身份**：Go 没有可读的账号信息。内部账号键为 key 的完整 SHA-256 十六进制摘要，只用于缓存绑定、账号切换判断和额度提醒去重；不展示，不写日志。摘要不可逆，不构成凭据片段。

**安全边界**：

- key 只发往 `https://opencode.ai/zen/go/v1/usage`，`User-Agent` 为 `cc-bar`，不冒充 OpenCode。
- 不写 OpenCode / Pi 的任何文件；只有用户手动填写的 key 存入 cc-bar 的钥匙串项。
- 日志和诊断只记录来源类别与 HTTP 状态，不记录 key、摘要或响应正文。

## 4. 额度数据映射

| 位置 | ID | kind | displayName | windowSeconds | 来源 |
|---|---|---|---|---:|---|
| `primaryLimit` | `opencode-go-rolling` | `.fiveHour` | `5HOUR` | 18000 | `usage.rolling` |
| `secondaryLimit` | `opencode-go-weekly` | `.weekly` | `WEEKLY` | 604800 | `usage.weekly` |
| `auxiliaryLimits[0]` | `opencode-go-monthly` | `.unknown` | `MONTHLY` | 2592000（约 30 天，与 Command Code 月窗口一致） | `usage.monthly` |

- `usedPercent = clamp(percent, 0...100)`；`status == "rate-limited"` 时取 100。剩余比例由 `QuotaWindow.remainingPercent` 统一计算，状态色走 `statusColor` 三档。
- `percent` 缺失或不是有限数字时，该窗口不进入快照，不伪造 0%。
- 三个窗口都无法解析时返回 `QuotaError.decode`。
- `planType` 不设置；Popover 副标题在没有账号信息时显示 vendor「OpenCode」。
- 快照沿用 `preservingFutureResetDates`。

## 5. 状态、错误与刷新

沿用 Command Code 的刷新门禁与失败处理：

| 情况 | 行为 |
|---|---|
| 未检测到 key | 账号为空；开启时 Popover 显示「未找到登录信息」 |
| 401 / 403 | 重读一次凭据，key 变化则用新 key 重试；未变化则显示失败。403 且响应含 `EntitlementError` 时提示「该 API Key 没有 OpenCode Go 订阅」，其余显示「登录已失效,请重新登录」 |
| 429 | 进入现有 10 分钟退避，手动刷新不绕过 |
| 网络 / 5xx / 404 / 响应无法识别 | `QuotaError.userMessage` 文案；保留并展示已有快照 |
| key 变化（账号键变化） | 立即清空内存与 `quota-cache.json` 中的旧 Go 快照，再请求新 key |
| 启动时缓存账号键与当前 key 不一致 | 同上，清空后再请求 |

- 定时刷新 60 秒最小间隔、`inFlight` 去重与其他服务相同。
- 开启开关、保存凭据后立即刷新一次。

## 6. 默认值与顺序

- `ProviderDisplaySettings.defaults(for: .opencodeGo)` = `enabled: false, menuBar: true, floatingHUD: true`，与 Command Code 相同：关闭时不联网；用户开启后直接出现在菜单栏和悬浮窗。
- `QuotaProviderDescriptor.allProviders` 末尾追加 OpenCode Go：Codex → Claude Code → Antigravity → Cursor → Command Code → OpenCode Go，其后是 Pi → OpenCode → DSH。已保存过顺序的用户，新服务追加在列表末尾（`normalizedServiceOrder` 现有行为）。
- `usageApp = nil`：设置列表里 OpenCode Go（额度）与 OpenCode（本地用量）是两行，各自开关。

## 7. 改动清单

### 7.1 新增文件

| 文件 | 职责 |
|---|---|
| `Core/Credentials/OpenCodeGoAuth.swift` | 凭据会话、来源、自动 / 手动读取、钥匙串存取、账号键 |
| `Core/Quota/OpenCodeGoQuotaClient.swift` | 请求端点、解析响应、映射 `QuotaSnapshot` |
| `Settings/OpenCodeGoCredentialSheet.swift` | 凭据面板，结构同 `CommandCodeCredentialSheet` |
| `CCBarTests/OpenCodeGoQuotaTests.swift` | 能力、凭据读取顺序、解析与边界用例 |

### 7.2 修改文件

| 文件 | 改动 |
|---|---|
| `Core/Quota/QuotaModels.swift` | `QuotaApp.opencodeGo`、`usageApp = nil`、Descriptor 追加 |
| `Core/Quota/QuotaRefreshPlan.swift` | `refreshOpenCodeGo` |
| `Core/Storage/Settings.swift` | 默认显示设置、凭据来源偏好 |
| `Core/Storage/QuotaCache.swift` | `opencodeGo` 便捷访问器（schema 不变） |
| `Core/AppState.swift` | 账号、额度状态、加载 / 刷新 / 存储 / 失败、提醒身份、日志 |
| `Core/Notifications/QuotaAlertPolicy.swift` | 支持三个 Go 窗口 ID |
| `Core/Diagnostics/DiagnosticsBundle.swift` | 凭据偏好与账号检测行 |
| `Main/DesignSystem.swift` | `tintColor` 用 `.opencodeAccent` |
| `Main/StatsView.swift` | 额度页筛选的穷举分支 |
| `MenuBar/PopoverRootView.swift` | 副标题、今日费用、服务状态的穷举分支 |
| `Settings/SettingsRootView.swift` | 服务行、凭据入口、来源说明、接入提示、关闭态说明、凭据面板 |
| `CCBarTests/QuotaAlertTests.swift` | 全服务提醒用例加入 Go |
| `ccbar.xcodeproj/project.pbxproj` | 新文件引用 |

## 8. 验证

- 单元测试：凭据读取顺序与手动模式、key 校验、响应解析（全部窗口、部分窗口、`rate-limited`、percent 越界、字段缺失、ISO8601 带 / 不带毫秒）、能力与默认值。
- Debug 编译。
- 没有真实 Go 订阅 key 时无法联调；真实响应的边界情况（如无订阅时的确切返回）靠用户反馈修正。

## 9. 风险

| 风险 | 处理 |
|---|---|
| 端点非公开，字段可能变化 | 集中解析；无法解析时报「返回的数据无法识别」，保留已有快照 |
| key 存在多处、不同步 | 自动模式按固定顺序取第一个可用 key；需要指定时用手动模式 |
| 环境变量从 Finder 启动拿不到 | 只作兜底；设置面板提示改用手动 key |
| 服务识别 / 风控 | 专用 `User-Agent`，遵守 429 退避 |
