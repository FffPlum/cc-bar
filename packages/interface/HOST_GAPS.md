# 主窗口接口核对

截至本次 React 主窗口实现，原先列出的阻断契约已由 Swift 宿主与 `@ccbar/host-api/window` 补齐并接入：

- 概览服务 KPI / 环比、宿主格式化费用明细、周期用满预估、价格目录显示币种。
- 项目当前范围天数、对话复制、Finder 项目定位、供应商外链、Pi 插件说明与复制。
- Gemini / Grok 本机登录卡、DeepSeek 来源和凭据所有权、通知权限与声音状态、更新状态。
- navigation / applications / authorizations / pricing / notifications / updates / appearance 失效事件；窗口初始化、导航失败及后台刷新失败都有恢复入口。
- `settings.setLaunchAtLogin` 为独立操作；启用额度通知或声音后显式请求系统通知权限。

主窗口账号列表沿用现有原生功能：Moonshot 仍可作为应用供应商 API Key，但没有独立额度管理行。DTO 保留的 `moonshot` 枚举值不代表已实现额度管理能力，前端不会展示无效开关。

前端不扫描文件、不访问凭据、不换算金额，正式入口不自动启用演示或 fake transport。仅 `tests/` 使用隔离的 fake transport；SDK 与前端一起验证真实方法名和响应 schema。

统计份额、5H/WK 周期卡、时间线当前窗口和历史恢复状态均已有宿主字段，前端按真实契约展示。测试和构建结果以最终验收记录为准。真实 macOS 权限、浏览器授权、更新器和系统窗口仍需宿主集成验收；通过前端测试不等于这些系统操作已手动验证。
