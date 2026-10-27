# Kimi Code 原生计时接入

状态：本机 Kimi Code 实施完成，Codex 审阅与验证完成；Debug 构建、测试目标编译及完整 XCTest 698 项（2 跳过、0 失败）通过，真实历史补扫、运行界面核对与固定本机签名打包均完成。详见 [验证记录](验证记录-Kimi原生计时.md)。

## 目标与依据

新版 `~/.kimi-code` 的 `context.append_loop_event / step.end` 带有 `llmFirstTokenLatencyMs` 和 `llmStreamDurationMs`。后者已经排除首字等待，不再减去首字延迟。请求用量仍只来自 `usage.record`，不能把 step.end 的 usage 重复入账。

## 实施方案

1. 按文件及 agent 隔离关联上下文，使用 step.begin 的 uuid / turnId / step、llm.request 的 turnStep 和原始四项 token 校验，将 step.end 计时附到同一步唯一的 usage.record。实际日志顺序为 begin → request → usage → end。重试、其他请求类型、错配、歧义与缺失均宁可不计时，不借用相邻请求时长；重复或重放事件不能重复计数。
2. 规范化 StoredEvent 增加可选 RequestTiming，并传入 UsageEntry；旧缓存缺字段兼容。原内容签名、模型、价格及 token / 请求口径保持不变。计时使用公共 RequestTiming 校验，无效值忽略，旧版及未记录计时的请求仍保留用量。
3. 启用 Kimi 的首字延迟与输出速度展示，沿用公共加权聚合、100 token / 500ms 速度样本门槛。精确原生计时不受 Pi 估算开关影响。
4. 提升 Kimi 统计规则版本并安全重扫旧扫描状态；保留已删除会话、子代理文件的缓存与去重所有权，失败不推进签名。逐会话贡献替换，自动重建与周期补齐均携带计时，重复启动不重复入账。
5. 测试覆盖原生字段、重复 token 的不同步骤、重试 / 子代理隔离、无效与缺失计时、旧版兼容、延后写入、增量缓存往返、版本升级保留删除历史、fork 去重及聚合替换。提供显式启用的真实日志验证方式，只输出脱敏汇总并验证补扫结果。
6. 同步技术实现、产品 / 界面文档及验证记录，明确旧日志不能凭空补计时。完成 Debug 构建、测试目标构建及完整 XCTest；脚本重新打包并校验签名及归档，按 git-commit skill 本地提交，不推送。

## 验收边界

首字延迟取原生延迟，token/s 为符合共享 100 token / 500ms 门槛样本的输出 token 总数除以原生流式时长总和。现存日志具备字段的历史记录能补齐，缺失字段显示无数据且不估算；精确原生计时不受 Pi 估算开关影响。源文件及日志正文不修改。保留其他来源和已删除历史，不替换 `/Applications/CCBar.app`。

## 第二阶段：真实日志只读审计

新增 `CCBarTests/KimiTimingAuditTests.swift` 并注册到 CCBarTests target。测试默认抛出 `XCTSkip`，只有显式把 `CCBar_KIMI_TIMING_AUDIT` 设为输出目录才运行；它只读扫描 `KimiSessionScanner.defaultRoots()` 下当时存在的真实日志，不读取或修改 CCBar 的真实用量历史。

审计在内存中把完整扫描得到的 v2 state 改为去掉全部 timing 的模拟 v1 state，再执行升级补扫，断言补扫前后请求数与四项 Token 合计不变；随后用补扫后的 state 再扫描一次，断言没有新条目且 state 不变。测试向指定目录写入 `kimi-timing-audit.json`，只含有效计时数量、请求数、四项 Token 与总 Token 合计、TTFT 均值、精确加权输出速度；没有对应样本时均值为 `null`。不输出账号或会话身份、文件路径、模型、正文或凭据。

实际验证已完成：Debug 构建及测试目标编译通过；完整套件 698 项、2 跳过、0 失败，显式真实日志审计通过；默认单独运行审计为 1 项跳过、0 失败。生产历史已补入 4,969 条原生计时，请求数与 Token 合计不变，详见验证记录。
