# Kimi Code 额度接入验证记录

日期：2026-10-25。

## 实现范围

复用新旧 Kimi CLI 的本地 OAuth 登录或 managed provider 官方 API Key，支持有效期检查、自动续期、真实 401 后一次重试、周期刷新及手动刷新。新版目录锁与旧 Python CLI 文件锁分别兼容；续期在锁内重读凭据，原子写回并保留未知字段，不清空失效凭据。网络失败保留已有额度，429 后保持原有 10 分钟退避，切换账号后丢弃旧请求结果。

Kimi 作为额度 Provider 进入菜单栏、Popover、悬浮窗与提醒；设置沿用原 kimi 顺序与用量开关，只有一个服务行。展示接口实际返回的 5 小时、周、月总量、代码月额度；月窗口不猜固定天数。旧有本机用量和参考费用继续保留，不新增历史额度周期预测。图标使用 [Kimi 官网 favicon](https://www.kimi.com/favicon.ico) 原始资源，菜单栏提取透明模板蒙版以适配系统外观。

## 实际接口证据

读取本机已有登录态，只读请求官方 coding/v1/usages 成功，响应实际含 usages.limit_5h 与 usages.limit_7d 的 used_ratio、reset_time；因此订阅额度接口可用。未主动轮换真实账号的 refresh token，续期通过隔离凭据与假网络验证。接口字段与本地新版官方 JS CLI 的 quota 解析及旧 Python CLI 的 OAuth 实现交叉核对。未将访问令牌、刷新令牌、账号标识或完整响应写入验证文档。

favicon 从官网原始 HTML 的 shortcut icon 链接核对后下载，避免误用浏览器扩展替换的页签图标。原始 ICO 进入工程资源；图标测试检查模板图存在透明区域与可见区域。

## 自动验证

| 检查 | 结果 |
|---|---|
| Debug build | BUILD SUCCEEDED |
| Debug build-for-testing | TEST BUILD SUCCEEDED |
| KimiQuotaClientTests | 30 项通过 |
| KimiQuotaIntegrationTests | 14 项通过 |
| KimiSessionScannerTests | 15 项通过 |
| KimiUsageIntegrationTests | 12 项通过 |
| ProjectUsageTests | 16 项通过 |
| StatsOverviewModelTests | 7 项通过 |
| QuotaRefreshPlanTests | 15 项通过 |
| QuotaAlertTests | 34 项通过 |
| 本轮合计 | 143 项，0 失败；不是完整测试套件 |
| 工程格式与差异空白 | 通过 |

覆盖：新旧根目录、自定义目录、凭据优先级、过期与撤销记录、OAuth profile 越界拒绝、第三方地址隔离、四窗口与无效比例、错误包装拒绝、钱包余额排除、账号信息、HTTP / 网络失败、401 一次续期、429 缓存保留、异步切号、设置迁移、月窗口独立提醒、新版锁阻塞与过期锁恢复、旧版 flock、外部轮换采用、原子更新和 0600 权限、未知字段保留、invalid_grant 后文件保留、官网图标蒙版。

本机逐命令设置 DEVELOPER_DIR 指向完整 Xcode，并仅在参数中关闭项目证书签名，没有更改系统或工程签名配置。因本机 xcodebuild test 的 LaunchServices 启动错误，使用 Xcode 自带 xctest 加载同一 Debug 构建的 CCBar.debug.dylib 与测试 bundle；设置 XCTestBundlePath 使运行时使用隔离测试环境，进程退出码 0。依赖镜像与校验记录沿用 [用量验证记录](验证记录-Kimi用量追踪.md)。

部分实现由本地 Kimi Code CLI 完成：凭据只读加载、额度与用户资料解析、30 项客户端测试；随后由主任务审查和补齐续期、刷新、UI、缓存、提醒、集成测试及文档。

## 手动验收边界

尚未启动真实 App 逐项操作验收。用 Xcode 打开 ccbar.xcodeproj 运行，在设置开启 Kimi Code，检查菜单栏 / Popover / 悬浮窗额度、浅深外观图标、手动刷新与账号套餐，并核对启停、拖拽顺序和本机用量保留。真实自动续期未强制触发，已由假网络和隔离凭据验证；月额度只在账号返回时显示。本次没有替换用户安装的 App，也没有提交、推送或发版。
