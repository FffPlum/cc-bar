# React 主窗口接口契约 v1

状态：开发中。TypeScript 唯一事实来源是 `packages/host-api/src/window.ts`。前端从 `@ccbar/host-api/window` 导入 `WindowAPI` 和窗口 DTO；根模块只保留旧 v1 类型，避免同名 Usage/Quota DTO 冲突。前端不得直接读取 `window.webkit`；`macos.ts` 仍是唯一接触 WebKit 桥接的文件。统计方法由 `HostWindowUsageService` 实现，其余窗口域由 `MacOSHostService` / `HostWindow*` 实现。

## 1. 调用、校验与事件

- 复用同一个 `HostAPI`：`const windowAPI = new WindowAPI(hostAPI)`。`WindowAPI.dispose()` 只拆除自己的订阅，不销毁共享 HostAPI。
- 所有方法都有导出 DTO、输入类型和运行时 schema。响应对象拒绝未知字段；整数必须是安全整数，金额是十进制字符串，时间必须可由 `Date.parse` 解析，服务和币种 dictionary 的键也按真实集合校验。请求递归省略 `undefined`。
- 原生入口显式检查方法、字段、枚举、ID、长度、分页和范围；所有 patch 先完整校验再同步应用，未知字段返回 `invalid_params`。凭据原文只存在于明确写操作输入，不能出现在返回、事件、错误或日志中。
- 状态事件 domain：`usage`、`quota`、`settings`、`navigation`、`applications`、`authorizations`、`pricing`、`notifications`、`updates`、`appearance`。事件只表示失效，前端重新请求快照；系统浅深色变化通过 `appearance` 刷新 bootstrap。revision 是进程内不透明字符串。
- `window.bootstrap` 返回 route、语言、宿主 platform/timeZone/appearance/version、带图标的侧栏应用和能力，以及按设置顺序排列的 `visibleUsageServices`。用量可见服务独立于侧栏是否添加应用；macOS 的 platform 为 `macos`，类型本身不限制未来宿主。
- `window.navigate({route})` 更新 `AppState.mainTab` 并返回最新 bootstrap；原生菜单、快捷键和侧栏移除应用后的回退通过 `navigation` 事件同步。
- 网络失败沿用旧快照和 429 退避；旧快照不代表本轮刷新成功，必须同时读取 `refresh`。
- PAT 导入、系统/钥匙串授权及诊断导出使用 10 分钟定向超时，更新价格并重算使用 30 分钟；额度刷新和启用账号为 2 分钟，重置次数查询为 1 分钟，其余请求沿用 HostAPI 默认 15 秒。超时仍不代表原生动作已取消。

## 2. 通用 DTO 与隐私

- 旧统计视图的自定义日期是宿主日历的 `YYYY-MM-DD`，结束日期包含当天；新仪表盘使用下述绝对时间半开区间。Swift 负责范围、时区、分桶、费用、汇率和缺价；JS 不重算业务。
- `UsageTotals` 保留 Token、请求、缓存、缺价/计量不完整、计时；`costUSD` 是原始美元，`costDisplay` 是 Swift 格式化结果。`UsageOverview.services[]` 独立提供每服务 current/previous/comparison/speed/models，不能由图表样本反推。
- `ConversationCosts` 每项均有对应展示金额；`CycleSummary.estimatedFullAllowanceCostDisplay` 和 `PricingModel.displayPrice` 同样由 `CurrencyFormatter` 生成。不可用值保持 null，不能伪造为 0。
- `BrandIcon` 含品牌、installedApp/favicon/brand/fallback 类型、受限 PNG data URI、填充规则及当前浅深色。图标来自 `ServiceIconResolver` / `InstalledAppIconLocator`，不暴露任意文件读取；设置/品牌变化后重新拉取。
- 账号和统计 ID 都是宿主分配的稳定 ID；统计路径与账户身份使用 opaque ID，前端不得拆解或构造。`ProjectIdentity.key`、`ConversationSummary.id` 和导入预览 ID 不得携带原始路径或隐私身份。快照不含 token、API Key、原始配置、凭据指纹或内部历史账号键。
- 隐私模式由 Swift 统一脱敏；对话 DTO 不返回 sourcePaths。`conversations.copyID` 与 `projects.reveal` 在宿主重新解析 opaque ID，隐私开启时拒绝。`platform.openExternal` 仅允许 http/https 并由系统浏览器打开。

## 3. 应用与供应商

| WindowAPI | RPC | 行为 |
|---|---|---|
| `applicationsList()` | `applications.list` | 检测、侧栏、用量开关、协议和宿主图标。 |
| `applicationsDetect()` | `applications.detect` | 调 `AppState.reloadApplications()`，不激活原应用配置。 |
| `applicationsSetVisibility(id,patch)` | `applications.setVisibility` | 分别更新侧栏和用量可见性；当前侧栏应用移除后路由回退。 |
| `applicationDetail(id)` | `applications.detail` | 登录摘要、错误及 `ProviderConnection.list` 连接卡；不提供编辑/删除/切换。 |
| `providersCatalog(application)` | `providers.catalog` | API Key、模型厂商、官网和默认 API 地址。 |
| `authorizationsSaveAPIKey(input)` | `authorizations.saveAPIKey` | 保存到 `AuthorizationStore`，返回脱敏 `APIKeyChoice`，不回显 key。 |
| `providersAdd(input)` | `providers.add` | 验证凭据同源、协议、模型和上下文后 `saveProvider`；只写 CCBar。 |
| `authorizationsGrantAccess(kind)` | `authorizations.grantAccess` | `claudeDesktop` / `cursor` 原生授权流程。 |

## 4. 额度账号

`quota.accounts` 包含主账号、导入 Codex、托管 Kimi、DeepSeek，以及不作为额度 Provider 的 Gemini/Grok `localLogin` 项。每项包含来源说明、`sourceOwned`、`sourceApplication`、needsRefresh、显示开关、快照/余额和退避。`serviceOrder` 只含真实额度服务。

| WindowAPI | RPC | 行为 |
|---|---|---|
| `quotaAccounts()` | `quota.accounts` | 完整账号和 Kimi/DeepSeek 授权状态。 |
| `quotaUpdateAccount(id,patch)` | `quota.updateAccount` | 修改启用、菜单栏、悬浮窗并 sync。 |
| `quotaReorder(serviceOrder,importedCodexOrder?)` | `quota.reorder` | 主服务与导入 Codex 分别按完整、唯一 ID 排序。 |
| `quotaRefresh(id?)` | `window.quota.refresh` | 整体或单账号原刷新链；独立于 v1 `quota.refresh`，不绕过退避。 |
| `quotaResetCredits(id)` | `quota.resetCredits` | 返回 `availableCount` 与 `{id,title,status,grantedAt,expiresAt}`。 |
| `codexPreview(payload)` | `codex.preview` | 单账号、批量 auth.json、PAT 的脱敏预览。 |
| `codexImport(input)` | `codex.import` | 批量 OAuth 保存；PAT 联网验证；仅该写操作接收原始 payload。 |
| `codexDelete(id)` / `codexRetryAccess(id)` | `codex.delete` / `codex.retryAccess` | 删除 CCBar 副本或重试旧钥匙串，不影响 CLI。 |
| `kimiStartAuthorization(input)` | `kimi.startAuthorization` | 地区、设备授权、可选重登，打开系统浏览器。 |
| `kimiCancelAuthorization()` | `kimi.cancelAuthorization` | 取消并隔离晚到结果。 |
| `kimiRetryAccess(id)` / `kimiDelete(id)` | `kimi.retryAccess` / `kimi.delete` | 重试钥匙串或删除托管账号，不改 CLI。 |
| `deepSeekStartAuthorization(input)` | `deepseek.startAuthorization` | 启动浏览器授权并查余额。 |
| `deepSeekCancelAuthorization()` | `deepseek.cancelAuthorization` | 取消任务与授权对象。 |
| `deepSeekRename(id,name)` / `deepSeekDelete(id)` | `deepseek.rename` / `deepseek.delete` | 改名或删除；前端依据 sourceOwned/sourceApplication 显示正确确认。 |
| `deepSeekRefresh(id)` | `deepseek.refresh` | 失败保留旧余额。 |

## 5. 统计域（HostWindowUsageService）

| WindowAPI | RPC | 行为 |
|---|---|---|
| `usageOverview(query)` | `window.usage.overview` | `StatsOverviewModel` + 对话概览；总 KPI、每服务 KPI/环比、图表上下文、速度、构成、模型和排行。 |
| `usageDashboard(query)` | `window.usage.dashboard` | 四项 KPI、可展示日志条数 `requestLogCount`、来源/模型级联选项、聚合表、小时/日/月趋势与覆盖信息。 |
| `usageRequests(query)` | `window.usage.requests` | 已核验请求索引；按时间/费用/Tokens 全局排序后以页码分页，默认每页 12、最多 500。 |
| `usageHeatmap(query)` | `window.usage.heatmap` | 周一对齐的 53 周日桶、区间汇总和全历史累计值；`nextBeforeDay` 保留供分页兼容，当前图表只展示最近 53 周。 |
| `usageRefresh()` | `usage.refresh` | 原扫描链和状态。 |
| `conversationsList(query)` | `conversations.list` | 搜索、项目、服务、日期、排序和宿主分页；默认 200、最大 500。 |
| `conversationDetail(id,metric?)` | `conversations.detail` | 全生命周期、模型、费用和性能。 |
| `conversationsCopyID(id)` | `conversations.copyID` | 宿主解析 ID 后写系统剪贴板；隐私拒绝。 |
| `projectsList(query)` | `projects.list` | worktree 归并、搜索/排序/分页和未归属差额。 |
| `projectDetail(query)` | `projects.detail` | 合计/环比、趋势、模型、分支、worktree、对话与全部时间。 |
| `projectsReveal(projectKey)` | `projects.reveal` | 宿主解析并校验项目路径；隐私拒绝。 |
| `quotaAnalytics(query)` | `quota.analytics` | 周期卡、费用/用满预估和 `QuotaHistoryStore` 时间线。 |

列表返回 `{rows,total,offset,limit}`；越界返回空 rows。详情 ID 不存在返回 `not_found`。

### 仪表盘范围与覆盖

上述 offset 列表规则适用于原有对话/项目；仪表盘请求使用独立的 `page/pageSize` 页码参数。`DashboardQuery` 包含 `range`（today / last24h / last7 / last14 / last30 / all / custom）、`metric`（cost / requests / tokens / cacheHitRate）及可选 service / sourceID / modelID。自定义 `customFrom/customTo` 为 ISO 绝对时间，范围为 `[from,to)`；`followNow` 为 true 时终点由宿主当前时刻确定。响应 `resolvedRange` 返回 from / to / timeZone / asOf / granularity。

- 自然日预设保留权威日汇总（含今天已接纳用量）；近 24 小时为实际 86400 秒。自定义部分日与小时趋势只用可核验事件，不能把没有时间戳的日汇总平均分摊。超过 730 天的非小时趋势按月分桶。
- 趋势 `samples[].segments` 必填，逐应用返回 `service / totals / value / label / share`，按可见服务顺序排列，遵循与整柱相同的筛选和分桶。费用、请求、Tokens 的 value 为应用实际指标，share 为该值占整柱值的比例。缓存命中率的 value 为应用缓存读取量除以整柱总输入量，label 标示百分点贡献，share 为应用缓存读取量占整柱缓存读取量的比例；各段 value 之和等于总体命中率，不累加各应用独立命中率。零分母的 share 为 0。热力图 DTO 不增加 segments。
- `axisTicks` 固定返回位置 0 / 0.5 / 1 的三档标签，并与 `samples[].normalizedValue` 共用同一 scale。普通指标从 0 起按最大柱值向上取整齐步长和上限；费用 scale 先乘显示汇率，但 samples / segments 的原始 value 仍保留美元指标，轴标签才使用显示币种，不能再次换算。命中率上限为 1，下限按有输入侧 Token 柱子的最低命中率计算；无有效样本为 0。`normalizedValue` 是对应指标值在 scale 范围内的归一位置并截断到 0～1，而不是固定除以原始最大值。请求数、Tokens 和百分比轴标签最多一位小数。
- `facets.services` 固定返回全部已启用用量应用，按设置顺序排列，所选范围没有用量的应用 `requestCount` 为 0；前端应用按钮直接读取 bootstrap 的 `visibleUsageServices`，加载或失败时也保持稳定。来源/模型候选仍由范围内实际用量生成。确认空用量的 `kpiDisplay` 返回 `—`，趋势保留范围内零样本和有效基准轴刻度。
- 当前前端统计卡片在非空态不使用 `kpiDisplay.tokens` 的本地化文本，而是从 `totals.totalTokens` 调用 `formatTokensCompact`；请求日志及供应商/模型聚合表的 Token 列使用同一函数。这些位置固定显示 K / M / B 和最多三位有效数字，中文不切换为万、亿；`kpiDisplay.tokens` 继续保留给既有客户端，空态 `—` 不变。
- `sourceID` 表示应用的会话日志或远端计量来源，不代表当前供应商配置或 API Key 的历史归属。来源与模型级联选项含请求数量；聚合表的 `successRate` 缺少失败分母时为 null，请求 `status` 为 unknown。
- `coverage` 含 event / day / mixed 精度、incomplete、refreshing、unlocatedTotals 和 message；它描述请求时间与来源覆盖。`refreshing` 为必填布尔值，表示宿主正在准备请求明细；期间保留已有统计并显示更新提示，完成后再提示仍存在的覆盖缺口。金额缺价/不完整使用 `UsageTotals` 中的独立标记，不能混为时间戳缺失。
- 概览 `requestLogCount: number | null` 为当前日期、应用、来源、模型筛选下可展示的日志行数，与明细 COUNT 使用同一 SQL 条件：仅已核验分区、范围内且请求数大于 0 的行。它不等于权威汇总 `totals.requestCount`，不计入只有汇总的历史请求和请求数为 0 的附属用量。概览只执行 COUNT，不读取明细行；索引尚未就绪返回 null，确认没有可展示日志返回 0。即使覆盖不完整也显示实际可展示条数。
- 明细只在请求日志页签打开后查询。`page` 从 1 开始（最大 10,000,000），`pageSize` 默认 12（1～500）；响应返回 `page / pageSize / totalCount / rows`，SQL COUNT 与当前页查询在同一事务内完成。页码超出末页自动收敛到最后一个有效页，空结果为第 1 页。每次页码查询读取当前快照，滚动范围按当前时刻重新解析；不冻结跨页快照，因此新增/删除记录后页边界可能变化。相同排序值按请求 ID、应用稳定排序。
- 前端每页条数提供 12 / 24 / 48 / 96，切换筛选、排序或每页条数回到第 1 页；页码可输入跳转。筛选、排序、page、pageSize 共同组成请求缓存键，旧请求不能覆盖新查询。失败保留已有行与重试入口。
- 保留 `cursor/limit` 供旧客户端兼容（limit 默认 100、最多 500），不能与 `page/pageSize` 混用；`nextCursor` 仍在响应中返回。旧游标绑定数据版本、筛选、排序、可见应用与时区并冻结 from / to / asOf，过期返回 `invalid_cursor`。新前端不使用游标。
- 热力图每块 371 天，`toDay` 不含当天，`beforeDay` 使用上一块 fromDay；未来日期仅作网格占位。当前每天/每周/历史累计视图只查询并展示最近 53 周，分页接口保留兼容。Cursor 的全部时间汇总与历史累计仅包含已加载远端历史，图表查询沿用有限区间补拉、账号/区间去重与退避，不为累计曲线发起无界回溯。
- `DashboardHeatmap.cumulativeFromDay: string | null` 为当前服务、来源、模型及可见性筛选下首次已记录用量的本地日期；没有历史记录时为 null。`days[].cumulativeTokens: number` 是从该历史起点至该日期的原始 Token 累计值，窗口起点已包含早于 `fromDay` 的记录。宿主从筛选后的 canonical 权威日桶计算前缀和，并遵循当前日、部分日的既有规则，不通过载入全部历史请求求和。零使用日累计值保持不变；它与仅表示当日用量的 `days[].totals.totalTokens` 不同，前端不得用 53 周窗口内从零求和替代，也不得计算为最近 7 天滚动和。累计字段必须显式返回并通过运行时 schema 校验，缺失字段不能默认补零；提示卡使用历史起始日至当前日期及累计值，不显示实际天数/7。
- DSH、Cursor、被删除日志及日级补录可能只有日桶。持久化旧日桶没有原时区元数据，切换系统时区不能完整重映射旧历史；接口不为此重写用户数据。

三个仪表盘查询立即读取可用索引快照，不等待日志重放。前端按完整查询缓存，60 秒内复用结果，非活动查询保留 10 分钟；宿主失效事件和可见页面的移动范围定时查询负责后台更新。切换到未缓存查询时标明暂显示上次结果，并禁用旧数据的分页等操作。隐私、语言、时区、可见服务或币种/汇率语义变化时隔离并清理旧查询上下文，不能复用敏感占位数据。

## 6. 设置、价格与系统动作

`window.settings.get/update` 使用完整 `WindowSettings`；v1 精简 `settings.get/update` 保留，不能混用 DTO。普通 patch 只包含同步偏好，不包含启动项注册、自动更新或权限请求。

- 外观：菜单周期、安装图标、悬浮窗、重置时间、状态点、隐私、排行、周期其他 Agent、Pi 估算速度、品牌色和最近色；`settings.resetBrandColors` 全量恢复。
- 数据：刷新频率及 `applySettingsChange`、真实代理枚举 `system/manual` 与 `http/socks5`、币种汇率、用量进度。`settings.testProxy`、`settings.refreshCurrency` 复用原链。
- 通用：语言、启动项实际状态、提醒偏好、通知权限、详细日志、版本与更新。阈值仅 5…50 步进 5，至少一个提醒周期。偏好保存和权限请求分离；`notifications.requestPermission` 返回独立系统状态。`NotificationState` 包含 alertsAllowed/soundAllowed/statusText，系统 allowed 显式映射为 authorized。
- `window.settings.setLaunchAtLogin` 是独立系统动作，返回最新实际状态；`updates.setAutomatic` 也是独立动作。`UpdateState` 包含 hasUpdate/isWorking，更新器 UI 保留原生。
- `pricing.catalog` 返回 models.dev 目录；`pricing.refreshAndRecalculate` 返回原结果与进度，不在 JS 重算。
- `notifications.rebuild/openSettings`、`diagnostics.export/revealLogs` 保留原生能力，诊断导出仍为脱敏 zip。

## 7. 错误与测试

标准错误码：`invalid_request`、`invalid_params`、`invalid_cursor`、`unknown_method`、`unsupported_version`、`unavailable`、`not_found`、`operation_failed`、`disposed`、`timeout`、`invalid_response`。

写操作返回最新快照或明确结果。宿主测试必须注入临时 store、动作 fake 和临时账号目录，禁止真实用户目录/设置/凭据读写；隐私测试需检查完整 JSON 不含原始路径、身份或秘密，而非只检查标题。TypeScript 使用独立 mock Transport，生产无 mock 回退。

### 统计展示与异步状态

- `TopConversation.share` 由宿主按排行指标计算；项目列表 `sharesByService` 按列表排序（最近使用取偏好指标），项目详情按偏好指标。未归属用量 `overviewShare` 优先费用、再 Tokens，无总量为 null。
- `QuotaAnalytics.window` 提供最新全局采样的剩余比例、采样时间和快照重置时间，不受当天曲线过滤影响。周期卡同时显示 5H/WK；下方时间线选择独立。
- `usage.refresh` 立即返回状态，在后台复用单一扫描任务。Cursor 历史补拉按账号与区间合并去重，同时包含比较区间和原生图表上下文（日 30 个周期，周/月 14 个周期）。
