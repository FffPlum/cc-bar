# React 主窗口 Debug 验证

日期：2026-11-01。分支：`feature/react-main-window`。基线为 develop 与 unified-host-api 前置提交；开发在独立 worktree 进行，原工作区的 Xcode Scheme 调试改动保留。

## 实施结果

- 默认主窗口使用 React、TypeScript 和 shadcn/ui（Base UI），保留应用、供应商目录、额度管理、四类统计视图和三类设置的结构与能力。
- Swift 保留菜单栏、Popover、悬浮窗、引导、权限/文件面板、更新器、凭据与业务数据。业务通过版本化 Host API 暴露；SDK 原有 v1 方法保持兼容，完整窗口类型放在 `/window` 子入口。
- WKWebView 加载 App 内的静态资源，限制可信来源、资源目录和外链。构建脚本、Xcode 资源阶段、SwiftPM 与 CI 已接入同一前端产物；生产页面没有 mock 回退。
- 增加响应数据校验、原生状态失效事件、导航同步、异步竞态隔离、隐私清理和授权取消。已接受的 PAT 导入、扫描、重算保持原业务任务生命周期；关闭窗口不等于撤销已接受的操作。
- Windows 的页面与接口边界已保留，Windows 托盘、窗口宿主和业务适配未实施。

## Debug 验证结果

1. 指定 Xcode Debug 构建通过，日志为 `** BUILD SUCCEEDED **`：

   ```bash
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project ccbar.xcodeproj -scheme ccbar -configuration Debug -destination 'platform=macOS' build
   ```

2. Swift 定向回归 70 项通过：42 项 XCTest、12 项应用/授权等 Swift Testing、16 项配置层 Swift Testing。覆盖 Host API、窗口账号/设置/统计、资源信任与越界、统计模型、应用导航及供应商配置：

   ```bash
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --skip-update --disable-automatic-resolution --filter 'HostAPI|HostWindow|WebInterface|StatsOverview|ConversationAggregator|ProjectStats|ProviderConfiguration|ApplicationNavigation|AuthorizationStore'
   ```

   首次拉取依赖遇到 GitHub 连接超时，随后使用锁定版本和已有缓存完成。后续仅修改设置测试夹具以补齐 `historyNotice` 字段，设置模块 7 项单独复跑通过。

3. TypeScript SDK 14 项通过（`npm test --prefix packages/host-api`）。其中窗口契约夹具由 Swift 隔离测试实际编码，涵盖非空统计周期、时间线、余额、授权状态和完整设置；全部通过 SDK 严格校验。格式化价格允许货币符号，金额原值仍要求十进制字符串。
4. React 30 项行为测试通过，类型检查与生产构建通过。覆盖初始化/导航/请求竞态、隐私缓存、表单、授权取消、排序、设置动作、额度统计及显示标签。最后一轮修复了下拉框枚举标签、Kimi 账号标记/地区重复和日期刻度拥挤。
5. `git diff --check`、构建脚本 `bash -n`、Xcode project `plutil -lint` 通过。

## 视图审查边界

在用户调整要求前，已在实际 WKWebView 中打开应用列表、应用详情、供应商目录及 API Key 取消表单、额度管理、统计概览/对话/项目和设置/价格目录，检查了 ⌘1 与 ⌘, 的导航同步，并复验了设置下拉框标签。没有保存、删除或重新授权用户的真实账号。

用户明确要求「编写完成后仅完成 Debug 测试，后面的视图审查由我来做」，因此停止进一步视图审查，不将上述抽查等同于完整 UI 验收。窗口最小尺寸、完整键盘/弹层交互、全部额度时间线、浅深色、关窗重开、全屏菜单 tracking 及真实系统授权/导入/通知等仍由用户后续验收。

本轮没有正式打包、发布、替换 `/Applications/CCBar.app`，也没有提交或推送。可用进程环境 `CCBAR_REACT_MAIN_WINDOW=0` 临时对比保留的原生窗口。

## 2026-11-01 统计视图修正复验

根据用户提供的四张原生/React 对照截图，由 GPT-6.1 Terra 修改前端，Codex 完成代码审查并要求补齐正占比归一、零用量服务提示、周期日期和展开行测试。修复占比条高度、图表提示框横向布局、实际柱体宽度、构成表格列宽及内容区分栏断点，并同步更新设计方案和界面布局。

- 前端 TypeScript 类型检查通过；全部 10 个测试文件、36 项测试通过。新增覆盖柱宽分档、实际柱体宽度、零用量服务、费用与 Tokens 独立汇总、跨年周标题、占比归一、四种构成维度、长项目名称/路径，以及提供商/模型展开和折叠后的数值列。
- 指定 Xcode Debug 构建通过，日志包含 `** BUILD SUCCEEDED **`。构建阶段同时完成 Host API 编译、前端类型检查和 Vite 静态资源生成；页面引用的产物均存在。
- `git diff --check` 通过。仅前端与文档变更，本轮未重复运行未改动的 Swift 业务测试；未打包发布、提交或推送。
- 日志：`/tmp/ccbar-react-stats-layout-tests.log`、`/tmp/ccbar-react-stats-layout-debug.log`。Xcode 仅报告未依赖 AppIntents 时跳过元数据提取的提示，无构建错误。
- 验收边界：以上是代码、行为测试与编译验收。JSDOM 不计算实际窗口布局；本轮未启动或操作应用做视觉验收，浅深色和实际窗口宽度下的最终视图仍由用户审查。

### 当前设备横向排列修正

用户要求当前设备最大窗口下「用量构成 / 高消耗对话」保持同行。只读查询确认屏幕逻辑分辨率为 1280 × 832；扣除侧栏和水平边距后的内容区约 1040px，因此将下排断点从 1100px 降为 960px，保留 5:4 比例、现有紧凑列宽和上排 880px 断点。仅修改该样式断点及文档，没有新增或重复运行行为测试。复跑指定 Xcode Debug 构建（含 TypeScript 检查和静态资源构建）通过，日志为 `/tmp/ccbar-react-stats-row-debug.log`；`git diff --check` 通过。实际窗口的视觉审查仍由用户执行。

### 占比条悬停与顶部间距

按照后续要求，概览滚动内容顶部增加 20px 内边距，与左右及底部一致。四个构成维度恢复主行与占比条的悬停联动：图标缩放、对应条段缩放和同色柔光、其余条段淡化、圆角中性行背景；零占比行不影响其他条段。系统减少动态效果时不缩放。保留 960px 分栏断点及既有行点击/展开行为。

GPT-6.1 Terra 编码，Codex 复查状态清理、样式作用范围及减少动态效果规则。前端全部 10 个测试文件、37 项测试通过，新增回归覆盖四维悬停、快速跨行、移出、零占比无动作行、范围与维度切换、行移除和后台刷新。指定 Xcode Debug 构建（含 TypeScript 检查和 Vite 构建）通过，`git diff --check` 通过。日志：`/tmp/ccbar-react-composition-hover-tests.log`、`/tmp/ccbar-react-composition-hover-debug.log`。本轮没有启动应用做视觉审查、提交或发布。

### 占比条圆角与缩放过渡调整

按用户调用的 animate 技能，将频繁悬停限定为轻微反馈：占比段改为固定 2px 圆角，缩放与透明度使用 160ms `ease` 双向 CSS transition；柔光使用固定阴影伪元素的透明度过渡，避免动画绘制阴影。增加细指针与可悬停设备限制，减少动态效果下只保留淡入淡出。没有新增动画依赖、改变比例数据或调整布局。

本轮仅修改相关样式与条段 class，未新增或重复运行行为测试。静态审查与 `git diff --check` 通过，指定 Xcode Debug 构建（含 TypeScript 检查与 Vite 构建）通过；日志为 `/tmp/ccbar-react-share-motion-debug.log`。缩放节奏、柔光及快速移入移出的实际观感仍由用户在 Debug 应用中审查。

## 2026-11-02 用量统计仪表盘

按照用户提供的新布局，Codex 制定方案、协调接口和最终审查，GPT-6.1 Terra 实现前端、宿主查询与只读请求索引。工作区为 `/Users/meitounao/.codex/worktrees/react-main-window/cc-bar`，分支 `feature/react-main-window`；原主工作区的 Scheme 修改保留。

已实现页头和时间/应用/来源/模型筛选、分钟级自定义范围与跟随当前时刻、四项 KPI 及小时/日/月趋势、可追加的 53 周热力图、请求/供应商/模型表及排序分页。全局侧栏和对话、项目、额度入口保留。旧概览及占比条 2px 圆角、160ms 悬停缩放仍保留在旧组件；新默认仪表盘使用新的全宽结构。

审查修复了已接纳日汇总与请求明细的口径差异、首次索引读入尚未接纳日志尾部、同值请求身份、零请求附属用量、临时文件读取失败后的重试、隐藏来源与全局模型选项、过期游标回包干扰新筛选，以及热图后台刷新和跨周的连续性。移动终点范围在可见页面每分钟刷新；固定自定义区间不推进。没有对真实账号执行重算、写入、授权或删除操作。

### 最终自动验证

- Swift 定向回归 **68 项通过**：64 项 XCTest、4 项 Swift Testing。覆盖 Host API/窗口域、资源边界、原统计模型、Claude/Codex/Pi 扫描器及请求索引。命令：

  ```bash
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --skip-update --disable-automatic-resolution --filter 'HostAPI|HostWindow|WebInterface|StatsOverview|UsageRequestIndex|ClaudeJSONL|CodexJSONL|PiJSONL'
  ```

- 额外以独立进程环境 `TZ=America/New_York` 运行 `HostWindowUsageTests.testDashboardAbsoluteRangeAndFilterIntersection`，**1 项通过**。确认 Foundation 读取该时区；测试覆盖 2026-11-01 回拨时两个本地同名小时的不同绝对样本键、自定义半开区间、24 小时时长、筛选交集与隐藏服务。未修改设备系统时区。
- React **12 个文件、54 项测试通过**，其中新仪表盘 17 项；TypeScript 检查通过。覆盖日期转换与不存在的 DST 时间、预设/自定义、级联筛选、排序、分页、异步过期响应、热力图更早页/刷新失败重试/跨周及移动范围时钟。
- SDK **15 项测试通过**，包括新查询/响应的严格校验。指定 Xcode **Debug build 通过**（`** BUILD SUCCEEDED **`），同时完成 SDK 编译、前端类型检查及 Vite 静态资源构建。没有使用 Archive。
- `git diff --check` 与 Xcode project `plutil -lint` 通过。最终构建仍报告 AppState 的未变变量和 actor 隔离警告，以及无 AppIntents 依赖的元数据跳过提示；初次完整编译也显示已有 JSONL 文件描述符 actor 隔离警告。本轮未把这些诊断扩展为无关重构。

日志：`/tmp/ccbar-dashboard-swift-final-tests.log`、`/tmp/ccbar-dashboard-dst-tests.log`、`/tmp/ccbar-dashboard-frontend-final-tests.log`、`/tmp/ccbar-dashboard-sdk-final-tests.log`、`/tmp/ccbar-dashboard-final-debug.log`。

### 已知边界与用户验收

- 原日志被删除、日级补录、DSH 与 Cursor 远端数据可能没有可核验的逐请求时间；日汇总保留，小时/部分日和请求表显示覆盖缺口，不分摊或伪造事件。成功率没有完整失败分母，显示 `—`。
- Cursor 全部时间仅含已加载远端历史；更早热图按页有限补拉并遵守既有去重和退避。OpenCode/Antigravity 数据库更新早于正常扫描时，相关分区事件可能暂缓，待扫描接纳后恢复。
- 旧持久化日桶未保存原时区元数据，切换系统时区不能完整重映射旧历史；本轮没有改写用户历史。
- 以上是静态审查、行为测试与 Debug 编译。按用户要求，未启动应用做本轮视觉验收；真实 1280×832 屏幕下的布局、浅深色、提示框及动画观感由用户检查。没有发布、替换已安装 App、提交或推送。

### 筛选栏尺寸统一

根据后续截图，将日期、全部/应用图标分段组、供应商/模型三组控件外框统一为 32px 高和相同圆角，文字 13px、图标 16px。应用按钮在固定组高内居中，消除原先图标行高及内边距撑高外框的问题；保留 8px 控件间距、内容宽度及窄窗口换行。

GPT-6.1 Terra 仅修改 `dashboard-filters.tsx` 的相关样式，Codex 静态复核并同步布局文档。`git diff --check` 和指定 Xcode Debug 构建通过（含 TypeScript 检查与 Vite 资源构建）；日志为 `/tmp/ccbar-dashboard-filter-size-debug.log`。没有新增或重复运行行为测试，未启动应用做视觉审查。

## 2026-11-02 统计缓存与后台更新

Codex 对照 cc-switch 查询与日志同步源码制定方案，GPT-6.1 Terra 完成代码变更，Codex 复审并运行最终自动验证。具体参考及数据边界见 [缓存方案](草案-React统计缓存与后台更新.md)。

- 新仪表盘使用 TanStack Query v5，按完整筛选缓存、合并请求，保留同查询的可用结果；切换到未缓存条件时保留并明确标注上一份数据。筛选栏持续挂载，按钮立即更新选中态，应用/来源选择与数据区采用短时透明度过渡并支持减少动态效果。
- 前端缓存按隐私、语言、时区、可见服务、币种及汇率等语义隔离；宿主事件和可见页面的移动范围定时触发后台更新。离开统计页保留结果，回到页面立即显示并重验。
- Swift 新增独立派生请求索引缓存，先后台恢复再更新，正常启动仍复用已有权威日桶和增量扫描进度。扫描或重建期间保留旧请求快照并合并后续更新；读取失败保留旧记录，Kimi 缓存身份不依赖本进程扫描标记。恢复、指纹和序列化移出主线程，串行原子写盘保留 0600 权限。
- 审查修复了 records/revision 不一致造成宿主长期缓存空结果、失败来源旧记录被过滤、扫描期间重复重放、重启 Kimi 索引失效，以及磁盘恢复被启动扫描阻塞的问题。普通 scanning 文案改为同步，明细准备期间独立显示更新状态。

验证结果：

1. Swift 定向回归 **99 项通过**（71 项 XCTest、12 项 App Swift Testing、16 项配置 Swift Testing），包含 9 项请求索引测试。覆盖重启复用、Kimi 持久状态、扫描暂停时先展示 sidecar、临时读取失败保留旧记录、已接纳日志边界和损坏缓存。测试使用临时目录。命令：

   ```bash
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --skip-update --disable-automatic-resolution --filter 'HostAPI|HostWindow|WebInterface|StatsOverview|UsageRequestIndex|ClaudeJSONL|CodexJSONL|PiJSONL|ConversationAggregator|ProjectStats|ProviderConfiguration|ApplicationNavigation|AuthorizationStore'
   ```

   随后仅修正扫描暂停测试自身的事件订阅竞态和 continuation 释放兜底，该项单独复跑通过；业务代码未再变动。
2. React **12 个文件、61 项测试通过**，TypeScript 检查通过；SDK **16 项测试通过**。覆盖缓存命中、同键去重、事件与时钟更新、隐私/汇率/可见服务隔离、按钮即时状态、旧游标和晚到响应、热图连续分页。
3. 指定 Xcode **Debug build 通过**，日志包含 `** BUILD SUCCEEDED **`，同时完成 Host API 编译、前端类型检查和 Vite 静态资源构建。仅出现已有 AppState 未变变量、actor 隔离及 AppIntents 元数据提示，没有新增编译错误。
4. `git diff --check`、构建脚本 `bash -n`、Xcode project `plutil -lint` 通过。原工作区的 Scheme 改动保持原样。

日志：`/tmp/ccbar-react-cache-swift-tests.log`、`/tmp/ccbar-react-cache-frontend-tests.log`、`/tmp/ccbar-react-cache-sdk-tests.log`、`/tmp/ccbar-react-cache-debug.log`。

首次升级尚无派生缓存时仍需后台建立一次索引；有效缓存之后可跨重启复用，变化来源仍会后台更新。按用户要求，本轮完成后创建一次本地检查点提交，不推送、打包或发布；未启动应用做视觉审查，真实窗口切换和动画观感交由用户验收。

### 统计趋势窄柱与应用占比

按后续截图要求，由 GPT-6.1 Terra 修改宿主、SDK 与前端，Codex 审查数据口径并完成最终 Debug 验证。小时/日/月样本增加逐应用分段，前端按主题色或自定义色堆叠，补充图例、悬停数值/占比及无障碍说明。柱宽复用原设计 28/18/10/5px 分档，保留整列命中区；去除固定列间距避免密集日期溢出。零贡献保留应用说明，不画虚假柱高。缓存命中率使用总体输入量加权的百分点贡献，不相加各应用自身命中率。

- `HostWindowUsageTests` **14 项通过**，新增断言覆盖小时事件与自然日桶、四项指标分段合计、应用筛选/隐藏和零分母；SDK **16 项通过**，包含分段必填与非法服务校验，热力图结构不变。
- 前端 `dashboard-stacked-chart`、`dashboard`、`dashboard-integration` 三组 **28 项通过**；新增测试覆盖分段比例、零值/单应用、图例顺序、浅深主题/自定义色、键盘提示与缓存贡献标签。最终仅调整提示数值区域宽度后，柱图 4 项单独复跑与 TypeScript 检查通过。
- 指定 Xcode **Debug build 通过**（`** BUILD SUCCEEDED **`），同步完成 SDK、TypeScript 和静态资源构建；仅有既有 AppIntents 元数据跳过提示。`git diff --check` 通过。
- 日志：`/tmp/ccbar-dashboard-stacks-swift-tests.log`、`/tmp/ccbar-dashboard-stacks-sdk-tests.log`、`/tmp/ccbar-dashboard-stacks-debug.log`。未启动应用做视觉验收；本次改动尚未提交或推送。

### SQLite 用量明细缓存

用户要求在 `feature/react-main-window` 引入 SQLite，随后明确忽略旧 JSON 明细，首次启动重建数据库。6.1 Terra 报告执行额度不足后，用户授权主代理接手；主代理完成存储和接线，独立子代理编写 SQLite 用例并静态复核。

`UsageRequestIndexStore` 改用系统 SQLite3，在 `request-index.sqlite3` 中逐行保存明细，以事务同步来源指纹和记录；金额保持精确 Decimal，未变来源不重写请求行。旧 `request-index-v1.json` 从不读取或迁移，原历史汇总与扫描进度快照不变。缺库/确认损坏由后台索引链重建，锁占用、权限/I/O 或未来版本返回不可用并延迟重试，避免误发布空缓存。实现边界与故障策略见 [SQLite 缓存方案](草案-SQLite用量明细缓存.md)。

- 首轮索引测试 18 项通过；补充加载结果分类后，最终 `UsageRequestIndex|HostWindowUsage` 定向回归 **32 项通过**，其中 SQLite 9 项、已有请求索引 9 项、宿主统计 14 项。
- 真实 SQLite 测试覆盖文件格式/0600 权限、精确金额/NULL/计时、旧 JSON 忽略与保留、未来版本、外部排他锁、损坏隔离重建、空指纹来源、来源移除；通过数据库触发器验证未变来源不重写，以及事务中途失败回滚行和元数据。所有数据库与日志均为临时测试数据。
- 指定 Xcode **Debug build 通过**，同时完成 Host API、TypeScript 和 Vite 资源编译。日志包含 `** BUILD SUCCEEDED **`，仅有既有 AppIntents 元数据跳过提示。`git diff --check` 通过。
- 没有改变前端或窗口 DTO，因此没有重复运行前端/SDK 行为测试；没有启动 App 操作真实用量目录、迁移旧数据、打包或发布。新库将在用户下次启动本分支构建的 App 时由后台建立。验证通过后，按用户要求创建本地提交。

日志：`/tmp/ccbar-sqlite-cache-tests.log`、`/tmp/ccbar-sqlite-cache-final-tests.log`、`/tmp/ccbar-sqlite-cache-debug.log`。


### SQLite 查询与前端结果缓存

日期：2026-11-02。用户要求进一步对齐 cc-switch：启动不恢复全量明细，明细筛选、排序、分页、计数与聚合由 SQL 完成，前端保留查询结果并后台更新。工作区仍为 `feature/react-main-window`。

- `UsageService` 移除全量请求快照和请求到会话的常驻映射；启动只读取来源/事务元数据。后台逐来源解析、校验、事务提交后释放临时记录，失败来源保留旧行。
- `UsageRequestIndexQueries` 用同一读事务处理关联查询，SQL 完成明细筛选和聚合，按 COUNT/ORDER/LIMIT/OFFSET 返回当前页。Decimal 聚合/排序保持精度，小时使用 Calendar 区间，分区与权威日桶核验。自然日汇总继续保留已清理日志的历史。
- Host 移除内存明细筛选、排序、分区核验缓存；取消查询不误标数据库故障，数据库不可用返回错误，前端不会收到伪造空结果。
- React 请求分页补上旧结果保留；筛选/分页失败保留可用内容、标记旧结果、禁用旧游标并提供重试。游标过期后先使首页缓存失效再重取，避免重复使用旧游标。

验证结果：

- Swift 定向回归 **43 项通过**（SQLite 18、请求索引生命周期 9、Host 16），日志 `/tmp/ccbar-sql-query-final-tests.log`。覆盖精确金额与排序、条件分页、计时聚合、覆盖缺口、夏令时重复小时、并发读取、取消、重启复用、来源局部写入与失败保留，以及畸形金额/计数隔离和合法金额溢出不误删库。测试只使用临时数据。
- React 定向回归 **30 项通过**，日志 `/tmp/ccbar-sql-query-frontend-tests.log`；覆盖缓存返回、切换/翻页失败保留、后台事件刷新不卸载表格和失效游标恢复。TypeScript 静态检查通过。
- 指定 Xcode Debug 构建 **BUILD SUCCEEDED**，日志 `/tmp/ccbar-sql-query-debug.log`；包含 SDK / 前端 TypeScript 与 Vite 构建。新 SQL 扩展显式标记 nonisolated，新增代码没有 actor 隔离警告。
- `plutil -lint ccbar.xcodeproj/project.pbxproj` 与 `git diff --check` 通过。实际界面/动画观感仍由用户验收；未启动或替换安装的 App。验证通过后按用户要求创建本地提交，未推送。

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --skip-update --disable-automatic-resolution --filter 'UsageRequestIndex|HostWindowUsage'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project ccbar.xcodeproj -scheme ccbar -configuration Debug -destination 'platform=macOS' build
```


### 固定应用筛选与空数据布局

日期：2026-11-02。先按用户要求提交 SQL 查询与前端缓存改动（`68c4f46`），随后单独实现本节更新。

- 应用分段按钮读取 `bootstrap.visibleUsageServices`，按已启用用量应用的设置顺序显示，不随日期范围、查询数据或侧栏成员变化；关闭当前应用后回到全部。Host `facets.services` 同步为固定启用列表，缺少用量时计数为 0。
- 确认空用量且索引就绪、覆盖完整时，KPI 为 `—`；空图保留网格、时间轴与合理基准纵轴，表格保留列头、页签数量 0，居中显示「暂无数据」。零费用但存在请求/Token 时仍显示真实值；索引准备、错误、历史覆盖缺口与旧占位数据不冒充空成功状态。
- 前端定向 **40 项测试通过**，日志 `/tmp/ccbar-dashboard-empty-tests.log`；TypeScript 静态检查通过。覆盖启用应用稳定顺序、侧栏外应用、关闭选中应用、空表结构、错误/加载与真实零费用用量。
- Host 定向 **19 项测试通过**，日志 `/tmp/ccbar-dashboard-empty-host-tests.log`；指定 Xcode Debug 构建 **BUILD SUCCEEDED**，日志 `/tmp/ccbar-dashboard-empty-debug.log`，包含最终前端资源编译。
- `git diff --check` 通过。视觉效果由用户验收，未启动或替换安装的 App；本节验证通过后按用户要求创建本地提交，未推送。
