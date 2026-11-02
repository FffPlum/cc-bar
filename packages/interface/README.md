# CCBar 主窗口

React / TypeScript / shadcn（Base UI）实现应用、供应商目录、额度管理、统计与设置窗口。Swift 保留菜单栏、系统窗口、凭据、数据扫描和所有平台操作。

- 开发入口：`src/main.tsx` → `BridgeGate` → `HostProvider` → `App`。
- 窗口类型与接口从 `@ccbar/host-api/window` 导入；根模块只用于 HostAPI/transport。
- 生产构建输出到 `Sources/CCBar/Resources/WebInterface/`，使用相对路径及限制联网的 CSP，由 Swift 自定义 scheme 加载。入口不提供模拟数据回退。
- 金额展示、统计份额与隐私脱敏由宿主提供；前端负责布局、交互和请求状态。开启隐私时立即清除前一模式的页面缓存。

在此目录执行 `npm ci` 后，可用 `npm run typecheck`、`npm test` 和 `npm run build` 验证。测试使用真实 TypeScript SDK 与隔离 fake transport，不调用实际应用、系统权限或用户凭据。测试包含初始化/导航竞态、旧响应、隐私缓存与查询、表单、授权取消、账号排序、设置平台动作及额度周期筛选。

实际 macOS 窗口与权限流程由 Xcode 集成验收。Windows 需实现相同契约的宿主和 transport；当前正式入口选择 macOS transport。
