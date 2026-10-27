# Kimi Code 原生计时验证记录

日期：2026-10-27。实施与审阅方案见 [执行计划](草案-Kimi原生计时-执行计划.md)。本机 Kimi Code 完成实现，Codex 审阅并修正测试，统一执行以下验证。

## 构建与测试

- Debug `build` 成功；仅在命令中使用 `CODE_SIGNING_ALLOWED=NO`，未修改工程签名配置。
- Debug `build-for-testing` 成功；命令使用 ad-hoc 签名覆盖。Xcode 自带 `xctest` 加载同一构建的 `CCBar.debug.dylib` 与 App 内的 `CCBarTests.xctest`，并设置 `XCTestBundlePath` 隔离应用启动副作用。
- 完整套件 698 项：696 项通过、2 项跳过、0 失败，退出码 0。跳过项为本机无 Command Code 凭据、未配置真实用量 golden fixture。此次没有宣称标准 `xcodebuild test` 的 LaunchServices 启动流程通过。
- 新增覆盖原生字段、流式时长不重复减首字等待、同 token 不同步骤、跨文件与同文件交错 agent、错误 agent 结束事件、重试、歧义、非法数值、旧用量兼容、延后写入、缓存往返、升级失败保留进度、删除历史及 fork 所有权；集成测试走自动规则升级、提交、重启与完整重算。
- `KimiTimingAuditTests` 默认单独运行时为 1 项跳过、0 失败；显式设置 `CCBar_KIMI_TIMING_AUDIT` 后，完整套件实际执行真实日志只读审计。

## 真实日志与历史补扫

只读审计扫描新版及旧版日志，比较模拟 v1 无计时基线与 v2 补扫的请求及四项 Token 合计，并确认再次增量扫描不重复产生条目。脱敏结果：

| 项目 | 结果 |
|---|---:|
| 请求数 | 5,759 |
| 普通输入 Token | 38,139,466 |
| 输出 Token | 4,176,039 |
| 缓存读取 Token | 876,859,577 |
| 缓存写入 Token | 0 |
| 总 Token | 919,175,082 |
| 可用原生计时 | 4,969 |
| 平均首字延迟 | 6.30 秒 |
| 精确加权输出速度 | 58.53 token/s |

退出原运行实例后，先在仓库外备份 `current.json` 和 `previous.json`，再运行标准打包脚本生成的签名 App 副本。首次启动的系统钥匙串授权由用户完成。实际日志记录自动 `stats_rules` 重建提交成功；生产快照的 Kimi 扫描状态与统计规则均升至 v2，日桶与对话桶各有 4,969 条首字计时，仍为 5,759 个请求，四项 Token 与升级前完全一致，其他服务的请求与 Token 合计未减少。源日志未修改。

运行界面已核对：Kimi 概览显示输出速度，对话详情显示「首字 4.8s · 输出速度 38 t/s」（所选对话，与全历史均值不同）；模型显示沿用去前缀规则。没有原生字段的历史仍显示无计时，不进行估算。

## 打包

- 唯一入口 `./scripts/build.sh` 完成 Release 构建及打包，传入现有 Sparkle 公钥；自动使用既有 `CCBar Local Signing` 固定本机证书。
- `codesign --verify --deep --strict`、`hdiutil verify`、`unzip -tq` 均通过。
- 产物为 `dist/CCBar.dmg` 与 `dist/CCBar.app.zip`，版本保持 1.1.30，架构 arm64。
- 当前运行仓库外的新版验证实例；未覆盖 `/Applications/CCBar.app`，未改动用户的 `dist-official/`，未推送或发版。
