# Codex 前端审查 · 第二轮

本轮独立只读审查确认的问题（以当前文件为准，行号可能随开发变化）：

| 优先级 | 文件（packages/interface/src 下） | 修正要求 |
|---|---|---|
| P1 | features/applications/provider-catalog-view.tsx / application-detail-page.tsx | openai/anthropic 是 Supplier，不是 ServiceBrand；需要显式映射 codex/claude 或宿主 icon。undefined 颜色导致 service-icon 的 hex.replace 崩溃。 |
| P1 | provider-catalog-view.tsx | authorizationsSaveAPIKey 返回 APIKeyChoice，不能作为 ProviderCatalog setData；保存后重新读取目录。AddProviderInput 要带 supplier。Base UI Dialog 不支持当前 onEscapeKeyDown 用法，按真实 API 接入。 |
| P1 | host/host-context.tsx | 初始 settingsGet 先失败、bootstrap 后成功会清除错误，settings=null 导致永久 Loading。独立维护各请求错误或初始组合加载；已有数据后的导航/刷新错误也必须有可见恢复出口。 |
| P1 | features/quota/quota-page.tsx | 当前拖拽把落点当 source，account.id 当 QuotaService，方向/ID域错误。Alt+上下传 previous/next 虚构ID。实现明确源/目标、用真实完整顺序，分别处理主服务和Codex子账号；不要用 never/as掩盖类型。 |
| P1 | features/quota/account-dialogs.tsx | start请求未回时取消，inProgress=false 导致没调宿主取消，后续授权继续。处理pending start及卸载，保证取消最终传到宿主，捕获cancel错误。成功完成有明确反馈或收起，不恢复为再次开始。 |
| P1 | account-dialogs.tsx Codex导入 | preview pending仍能改payload，旧响应生成旧preview而保存新payload。冻结请求对应草稿或用generation使旧预览失效，保存必须与最后成功预览一致。 |
| P2 | provider-catalog-view.tsx | 保存pending时不能让Esc/右上关闭/点外部悄悄丢失反馈。使用正确Base UI关闭策略并锁定相应输入，或安全完成后明确刷新；不只禁用取消按钮。 |
| P2 | account-dialogs.tsx ResetCredits | 不在useState initializer启动网络副作用（StrictMode会重复），使用effect并处理过期响应，恢复失败“重试”入口。 |
| P2 | quota-page.tsx删除确认 | 按 sourceOwned/sourceApplication 区分DeepSeek原应用副本和CCBar自建授权，删除文案/行为保持一致。 |

功能等价修正：上下文默认128000；不支持配置的应用仍允许进目录保存Key，仅禁用关联已有Key；两表单支持Return默认提交和厂商获取Key链接；Key搜索包含供应商名；来源/协议使用显示名称；添加供应商成功后留在目录；授权完成有明确反馈。

务必读 `docs/React集成审查.md`：SDK窗口类型改从 `@ccbar/host-api/window` 导入，Vite/tsconfig增加先于根模块的精确alias。旧根模块v1同名类型不可混用。

这些缺陷应补隔离行为测试：初始RPC乱序一成一败、排序源目标、授权start后立即cancel、输入变化后旧preview返回。修复后继续完成统计/设置所有页面，不能遗漏 HOST_GAPS 中原有功能。
