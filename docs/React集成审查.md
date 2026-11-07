# Codex 集成审查记录

## SDK 导出冲突（必须在类型检查前解决）

旧 `packages/host-api/src/index.ts` 已定义并导出 `UsageTotals`、`UsageOverview`、`QuotaSnapshot`、`QuotaLimit` 等类型。新 window.ts 又定义同名但不同结构，单纯 `export * from './window.js'` 会让消费者拿到根模块旧类型（或产生导出冲突），不能这样统一导出。

设计决定：新增明确 `@ccbar/host-api/window` 子路径，导出 window.ts / dist/window.js。原根模块保留 v1 API/类型；窗口类型和 WindowAPI 从 window 子路径导入。React 的 Vite/tsconfig alias 为该子路径单独映射，顺序先于根 alias；测试也用同样入口。不要重命名或删除 v1 类型来破坏既有接口。

B 负责 package exports 与 SDK root 导出修正；C 负责 interface import 与 alias 调整；D 不受 TS import 变化影响。

## 接口缺口汇总来源

B/D 在完成前都必须读取 `packages/interface/HOST_GAPS.md`，除了既有审查还包括项目 rangeDayCount、Pi计时插件说明及复制内容等。补齐接口后 C 对照修复，文档只保留真实未完成项。

## Xcode GUI 的 Node 路径

A 的脚本当前只使用 PATH。当前本机 npm 在 nvm 目录，Xcode GUI 的 PATH 可能没有它。需提供明确可用的 NODE_BINARY/npm 配置或安全的常见安装路径发现；至少不要默默依赖从终端启动的环境。CI 使用显式 setup-node，命令行验证仍按项目指定 Debug 构建。
