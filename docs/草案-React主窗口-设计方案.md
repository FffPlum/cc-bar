# React 主窗口重构方案

状态：代码实施与 Debug 验证完成；按用户要求，后续视图审查由用户完成。基线：`feature/unified-host-api` / `1b3b08e`。用户要求沿用当前布局，React + shadcn/ui 重写面向用户的主窗口，前期由本地 Kimi Code 实现，额度耗尽后按用户要求由 Codex 接手剩余开发、设计审查和功能验证。

## 1. 目标与边界

- 将应用、应用详情、供应商目录与表单、额度管理、统计、设置主窗口迁移到共享 React 前端。
- 保留 Swift 菜单栏、原生菜单 tracking、Popover、悬浮窗、引导、系统文件选择/权限、更新器及全部业务服务。
- 首先完成 macOS。共享页面仅依赖类型化 Host API，不能访问 `window.webkit`、Node、macOS 路径或 UserDefaults；平台入口负责注入 transport。Windows 后续实现 transport 和宿主业务/系统能力，不能声称仅换托盘即可运行现有 Swift 业务。
- 以当前代码、界面布局和设计风格为依据，禁止使用 docs/Screenshots。应用卡片仍只展示连接信息，不新增切换、编辑、删除按钮。
- 不能以示例数字、空按钮、未接入表单、仅两项设置的壳代替现有功能。原生界面保留为开发回退，默认入口切换需以迁移验收完成为前提。

## 2. 架构

`packages/interface`（React、TypeScript、Vite、Tailwind、shadcn/ui）→ `packages/host-api`（数据契约、请求/事件、transport 注入）→ `Core/HostAPI`（验证、DTO、方法分派）→ 现有 AppState / ApplicationStore / AuthorizationStore / SettingsStore / UsageService。

- 业务单一来源：费用、汇率、排序、过滤、时区与日期分桶、额度周期/状态、429 退避、历史重算仍使用现有 Swift 模型；JS 只做显示、交互和局部视图状态。
- 金额保留十进制字符串和宿主格式化结果；缺价、不完整用量、旧快照与失败状态均需保留。
- 凭据只能作为明确保存/导入操作的输入，不在快照/事件/错误/日志中回传，不写 localStorage；普通列表返回脱敏后的展示字段和稳定 ID。
- 使用明确允许的方法与参数校验，拒绝未知字段、错误枚举、不合法范围；先验证再持久化。不得提供任意文件读取、任意 selector 执行或通用 UserDefaults 写入。
- 状态事件扩展至应用、授权、统计、额度、设置、导航；初始快照 + 订阅失效刷新，防止过期响应覆盖新查询。卸载时 dispose，并覆盖后台变化。
- 原生 MainTab 与 React 路由双向同步，保留菜单入口、⌘1、⌘, 和移除侧栏应用后的导航回退。

## 3. macOS 托管与打包

- 保留 AppDelegate 的窗口所有权、关闭释放、菜单 tracking 后异步激活、regular/accessory 策略。React 主窗口默认内容区调整为 1000×650、最小 900×600（逻辑像素），首次居中、可调整大小，并通过 `NSWindow` frame autosave 在关窗重开和应用重启后恢复上次位置与尺寸；前端根尺寸与宿主一致，窄窗口双栏按 2:3 弹性收缩并由页面内部滚动，避免内容被根容器裁剪。原生开发回退仍保留 1440×900 初始尺寸和 1040×520 最小尺寸。
- WKWebView 容器持有 service/transport，明确安装与拆除；主页面只加载打包的可信资源。采用 `ccbar-ui://app/index.html` 专用 scheme，主框架桥接须精确匹配可信 origin，资源读取限制到 bundle 根目录，防目录穿越/符号链接逃逸。
- 导航仅允许自身资源；http(s) 外链经宿主打开，不把远程页面加载到有权限的 WebView。禁用任意弹窗，设置 CSP、不使用远程脚本/CDN，不放宽文件读取/KVC 私有开关。
- 资源走 Vite 静态构建，保留相对路径；Xcode、SPM、scripts/build.sh/CI 都需可复现地取得同一份资源。Xcode 构建不得悄悄联网安装依赖，首次依赖安装和资源构建命令须文档化。正式打包脚本负责显式构建/校验资源，避免只在本机临时目录可用。
- 缺资源、桥接失败、Web 内容进程终止要显示明确恢复界面；不得静默白屏或用 mock 代替真实数据。

## 4. 页面与功能验收矩阵

| 页面 | 必须保留的布局和交互 | Swift 数据/行为来源 |
|---|---|---|
| 全局导航 | 200px 左栏，应用列表、额度管理、用量统计，底部应用/设置；选中态、键盘访问 | MainTab、ApplicationStore.sidebarApplications |
| 应用管理 | 已检测列表、重新识别、用量与侧栏两独立开关、空态 | reloadApplications、setAdded、setUsageServiceVisible |
| 应用详情 | 标题/添加供应商、连接卡、官方/使用中标记、原有错误与登录占位 | ProviderConnection.list、applicationLoginSummary |
| 供应商目录 | 返回、搜索名称/API 地址、165px 分类栏与计数、API Key/厂商/自定义、响应式卡片 | apiKeyProviders、ModelSupplier |
| API Key / 添加供应商 | shadcn Dialog，密码输入、校验、取消/保存、协议/模型/上下文、成功刷新；新增供应商不激活原应用配置 | AuthorizationStore、ConfigurationRepository.validate、providerCredential |
| 额度管理 | 主账号、导入 Codex、托管 Kimi、DeepSeek、额外登录；启用/菜单栏/悬浮窗、排序、导入/添加/移除和原有确认、刷新与退避 | quotaAccountProviders、AuthorizationServicesView 对应 AppState 方法 |
| 统计概览 | 顶栏服务筛选/刷新、可配置视图、日周月/自定义区间、KPI/对比、堆叠图/悬停、组成维度、排行/详情 | StatsOverviewModel、StatsView、CurrencyFormatter |
| 对话/项目 | 搜索、排序、日期/服务过滤、选择详情、项目分组、模型/渠道/性能/用量；隐私隐藏名称/路径和复制/打开操作 | ConversationStatsView、ProjectStatsView 及其聚合器 |
| 统计额度 | 账号/周期选择、官方进度、刷新/失败、额度与费用/用满预估、明细 | CycleStatsView 与现有额度模型 |
| 设置外观 | 菜单周期、悬浮窗即时同步、重置时间、状态点、图标、隐私、品牌色编辑/最近色/恢复、统计排行/性能选项 | SettingsStore、FloatingPanelController |
| 设置数据 | 刷新频率/进度、代理与测试、币种与汇率、价格目录搜索分组、更新价格并重算/失败保留/进度与结果 | Scheduler、NetworkProxy、CurrencyStore、PricingCatalogStore、UsageService |
| 设置通用 | 语言、开机启动实际状态、额度提醒权限/阈值/周期/声音/重建确认、诊断导出确认、日志、版本/更新/自动检查 | L10n、SMAppService、QuotaNotificationCoordinator、DiagnosticsBundle、AppUpdater |

## 5. 视觉与可访问性

- 使用真正的 shadcn/ui 源码组件及其 Radix/Base UI 原语，提供 components.json；保留紧凑桌面密度、系统字体、13px 正文、表格等宽数字、原有中性背景/细边框、轻阴影。
- 支持系统浅深色和应用中英语言切换；隐私在宿主 DTO 端脱敏，搜索输入使用密码形式。品牌色只用于识别，额度状态维持 ≥20% 中性、<20% 橙、0% 红。
- 对话框焦点约束/返回、Esc 关闭、Tab 导航、按钮可访问名称、加载/错误/空态、长文本截断或换行。最小窗口下所有操作可达。

## 6. 实施分工与顺序

1. Codex：核查基线，制定方案/契约和验收清单。独立 worktree 从 develop 创建后快进纳入 unified 前置提交，保留原工作区改动。
2. Kimi A：先做容器、安全资源加载、构建链和窗口生命周期；不改业务逻辑、不删除原生界面、不提交或推送。
3. Kimi B：扩展 Host API/SDK，复用现有 Swift 模型，提供契约 fixtures/必要边界测试；方法按页面域拆文件，避免巨大单体分派器。
4. Kimi C：根据已落地类型实现 React 页面/shadcn 组件与行为，补齐各页面，测试使用独立 mock transport，生产禁止自动 mock 回退。
5. Codex：审查 diff 和契约，对照逐页面矩阵；接手并修复剩余缺口，执行定向测试、前端构建和指定 Debug Xcode build，最后实际打开打包后的窗口验证。只有验收后切换默认窗口。

## 7. 验证与完成标准

- 宿主测试使用独立临时数据/设置、注入网络和平台动作。覆盖校验原子性、业务等价、凭据不回传、隐私、后台失效、路由双向同步、信任来源、资源越界、窗口拆除重开。
- 前端覆盖导航/筛选/表单校验与成功/失败/取消、异步竞态/订阅清理、空数据、加载失败/保留旧快照、两种语言/外观；不写只镜像实现的测试。
- `npm ci` + 前端类型/生产构建；宿主 SDK 回归；Swift 定向测试；Xcode Debug：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project ccbar.xcodeproj -scheme ccbar -configuration Debug -destination 'platform=macOS' build`。
- 最初的视图验收清单为：真正 WKWebView 中验收离线资源、真实只读数据、页面入口/搜索/取消、日期更换、快捷键、关窗重开、主窗口与原生菜单栏同时可用。2026-11-01 用户调整交付边界为仅完成 Debug 测试，剩余视图审查由用户执行。测试不改真实凭据、不重算真实数据、不替换 /Applications 安装。
- 更新常驻技术/布局/打包/Host API 文档，明确 Windows 未实现与剩余限制。不能以“构建通过”声称功能全部通过；报告验证范围和未完成项目。

## 8. 2026-11-01 统计视图对齐修正计划

用户提供原生与 React 截图，要求修复占比条、图表提示框、柱宽和构成表格溢出。由 Codex 定位和审查，GPT-6.1 Terra 编码，最后执行静态检查及 Xcode Debug 构建；实际视图审查仍由用户完成。

1. 占比条：将外层上内边距与内层 8px 高度分开；只绘制正占比，扣除 2px 段间距后按正占比总和归一分配宽度。保留宿主提供的占比和颜色口径。
2. 图表提示框：覆盖通用 Tooltip 的横向 flex 布局，恢复纵向卡片；周期标题、各服务费用、合计费用、Tokens、分隔线和输入/输出/缓存明细逐行显示。日期以宿主时区的统计周期为准，金额直接使用宿主格式化结果。
3. 柱宽：将原生 28/18/10/5px 分档真正应用于柱体，点击和键盘焦点区域独立保留，继续使用稀疏日期刻度。
4. 构成表格：移除 720px 强制最小宽度，使用固定数值列与可截断的名称列，缩小表头、数值和间距；提供商/模型的展开行复用同一列结构。根据内容区宽度切换单列或双列，保证各数据列可见。
5. 组件布局：显式指定面板标题栏为 flex，让标题和维度切换控件同行；仅对本次统计内容调整 Tooltip 和表格样式。
6. 验证：覆盖占比归一、四维度与展开行、提示框字段和柱宽边界，运行前端类型检查/测试、静态资源构建及指定 Debug build。测试不能代替实际窗口的视觉验收。

## 9. 参考

- shadcn/ui Vite 安装：https://ui.shadcn.com/docs/installation/vite
- Vite 静态构建/相对路径：https://vite.dev/guide/build.html
- WKURLSchemeHandler：https://developer.apple.com/documentation/webkit/wkurlschemehandler
