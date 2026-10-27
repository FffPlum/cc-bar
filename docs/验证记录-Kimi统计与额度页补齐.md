# Kimi 统计与额度页补齐验证记录

日期：2026-10-25。

## 实现与审查

主要实现由本地 Kimi Code CLI 完成，按用户要求使用 `kimi-code/k3.1-pro-highspeed`。本次调用新写出的 `llm.request.model` 为 `k3.1-pro-highspeed`，`usage.record.model` 为 `kimi-code/k3.1-pro-highspeed`，确认日志能够区分实际选择的型号。主任务负责架构设计、代码审查、边界补齐与最终验证。

- K3 / K3-256K / K3.1 Pro / Highspeed 仅在查价层精确映射到公开 API 型号，增加美元离线参考费率，价格和映射进入重算指纹；原始模型名、分组和去重身份保留。
- 概览模型名称和来源支持系统 hover。`kimi-for-coding` 显示「当前 K2.8 Preview」说明，无可靠公开价时显示 `—`；不把旧滚动路由重命名成当前具体版本，不把它按 K3 计费。
- Kimi 5 小时 / 周额度进入历史、周期卡与时间线，遵守服务开关和用户排序；宽屏最多四列，月窗口不伪造周期长度。新周期卡完全无法估算的费用同样显示 `—`。
- 历史与缓存共用凭据稳定账号键，缓存按原采样时间补记，拒绝异账号、异服务及旧于已有历史 / 周期样本的缓存；失败和 429 不生成假样本。
- 官方渠道与六个已知型号同时匹配才进入 Kimi 订阅周期，同前缀的自定义模型也排除。追加请求按会话替换贡献；周期补算复用已提交的去重事件，保留源文件删除后的记录。

## 自动验证

用户明确授权后执行 Debug 构建和相关定向测试。命令单独设置 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`，仅本次命令设置 `CODE_SIGNING_ALLOWED=NO`，未修改工程或系统签名配置。

| 检查 | 结果 |
|---|---|
| Debug build | `BUILD SUCCEEDED` |
| Debug build-for-testing | `TEST BUILD SUCCEEDED` |
| KimiQuotaClientTests | 30 项通过 |
| KimiQuotaIntegrationTests | 17 项通过 |
| KimiSessionScannerTests | 16 项通过 |
| KimiUsageIntegrationTests | 14 项通过 |
| QuotaParsingTests | 137 项通过 |
| StatsOverviewModelTests | 7 项通过 |
| QuotaRefreshPlanTests | 15 项通过 |
| UsageSafeRebuildTests | 42 项通过 |
| DshPricingTests | 9 项通过 |
| 合计 | **287 项，0 失败；不是完整测试套件** |
| 差异空白检查 | 通过 |

沿用已有验证记录中的独立 XCTest 运行方式：Xcode 自带 `xctest` 加载同一 Debug 构建的 `CCBar.debug.dylib` 与 App 内的 `CCBarTests.xctest`。设置 `XCTestBundlePath` 使 AppRuntime 使用测试隔离环境；扫描根、价格目录、历史数据均使用测试注入，未启动真实 App 采集。进程退出码为 0，并核对实际执行数量为 287，非空选择。最初测试编译暴露了新增用例访问私有缓存的问题，修正断言后重新编译通过。最终测试包含主任务修正后的周期边界、追加幂等及旧缓存防倒退用例。

构建日志为 `/tmp/ccbar-kimi-debug-build.log`，测试编译日志为 `/tmp/ccbar-kimi-test-build.log`，执行日志为 `/tmp/ccbar-kimi-targeted-tests.log`；临时日志不作为长期归档。无测试失败遗留，未运行完整测试套件。

## 待手动验收

在 Xcode 中打开 `ccbar.xcodeproj` 并运行 App：

1. 在概览模型维度确认 K3 / K3.1 有参考费用；`kimi-for-coding` 显示当前路由说明与 `—`，悬停能看到完整模型、来源和费用说明。
2. 选择全部服务及 Kimi 单服务，确认 5 小时 / 周周期卡、额度变化图、服务顺序、隐藏服务和宽窄布局。
3. 成功刷新并产生新用量后检查周期变化；首次记录前没有历史额度曲线属正常边界，用满预估仍需有效的用量与观察比例。
4. 检查浅色 / 深色外观和实际系统 hover。自动测试不代表真实界面已验收。

本次未替换 `/Applications/CCBar.app`，未提交、推送或发版，保留任务开始前的 `dist-official/`。
