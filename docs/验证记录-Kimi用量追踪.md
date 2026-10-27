# Kimi Code CLI 用量追踪验证记录

日期：2026-10-25。

## 已实现范围

初始用量接入让 Kimi Code 进入设置、概览、对话与项目页，支持服务混排及可见性开关。新版 `~/.kimi-code` 与旧版 `~/.kimi` 的请求用量统一采集，分别记录普通输入、输出、缓存读取和缓存写入；不将上下文占用或子代理汇总当作请求重复计入。

逐会话贡献与扫描状态一并提交。追加、fork 重放、截断、半行、读取失败、删除原会话或单个子代理日志，以及重启 / 重算后的历史保护均有确定性用例。只保留规范化的请求用量、标题和项目元数据，不保存消息正文。

模型价格沿用统一定价链，models.dev 新增全球 Moonshot API 的美元价格来源，排除订阅计划零价与地区换算价。自定义模型别名只有在同一历史请求明确记录 API 模型时才解析；初始阶段尚未建立 K3 / K3.1 的精确公开 API 映射，`kimi-for-coding` 等未核实路由不猜价格。无法定价的 Token 仍记录，不能据此理解为免费或真实订阅账单。本记录及下方自动验证对应初始用量阶段；后续额度接入见 [Kimi 额度验证记录](验证记录-Kimi额度接入.md)，K3 / K3.1 计价、缺价展示与历史周期补齐见 [Kimi 统计与额度页补齐验证记录](验证记录-Kimi统计与额度页补齐.md)。仍不增加请求计时。

## 自动验证

| 检查 | 结果 |
|---|---|
| Debug 构建 | `BUILD SUCCEEDED` |
| Debug 测试目标编译 | `TEST BUILD SUCCEEDED` |
| `KimiSessionScannerTests` | 15 项通过 |
| `KimiUsageIntegrationTests` | 12 项通过 |
| `StatsOverviewModelTests` | 7 项通过 |
| `ProjectUsageTests` | 16 项通过 |
| `QuotaParsingTests` 的官方 Fast 定价与 models.dev 解码用例 | 2 项通过 |
| 合计 | 52 项，0 失败；不是完整测试套件 |
| 工程文件格式、差异空白检查 | 通过 |

本机命令行默认指向 Command Line Tools，验证命令单独设置 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。缺少工程指定的开发证书时，仅在命令参数中关闭签名；没有修改工程签名配置。应用和测试均能编译，但 `xcodebuild test` 的 LaunchServices 启动器报 `IDELaunchErrorDomain / 20`，临时 ad-hoc 签名后也相同。因此使用 Xcode 自带 `xctest`，加载同一 Debug 构建的 `CCBar.debug.dylib` 与 `CCBarTests.xctest` 执行上述 52 项，进程退出码为 0。测试设置了 `XCTestBundlePath`，所有扫描根、历史快照与价格均使用临时隔离环境，不启动真实采集。

依赖下载中 Sparkle 的 Git 全历史传输中断，改用临时镜像获取 `2.10.0` 后验证提交为 `eef1a539a373c1f1a320624b1130fc5de7b2e100`；二进制包 SHA-256 为 `17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959`，与锁定提交中的官方清单一致。仓库依赖地址、锁定版本和系统全局 Git 配置未改动。

## 尚未手动验收

在 Xcode 中打开 `ccbar.xcodeproj` 并运行 App，检查：设置中 Kimi Code 的识别、开关和拖拽顺序；统计中的输入 / 输出 / 缓存拆分；对话标题与项目归属；追加对话后的刷新。核对有价模型的参考费用，并确认订阅路由缺价时不会误认为真实账单。此次没有替换 `/Applications/CCBar.app`。
